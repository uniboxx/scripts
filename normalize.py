#!/usr/bin/env python3

# Author: Davide Pedrotti
# Create: 19/11/26
# Update: 25/11/26
# Description: Normalize or analyze audio in video files (2-pass EBU R128, parallel)
# Requirements: python3, ffmpeg, ffprobe, trash
# Usage: normalize [-a] [--lra VAL] [-k] [video_files ...]
# for help: normalize -h

# import modules
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading

# colors
reset = "\033[0m"
white = "\033[1;37m"
red = "\033[1;31m"
cyan = "\033[1;36m"
green = "\033[1;32m"
yellow = "\033[1;33m"
magenta = "\033[1;35m"
orange = "\033[1;38;2;255;153;0m"

# parse command line arguments
parser = argparse.ArgumentParser(
    description="Normalizza o analizza l'audio EBU R128 dei file video.",
)
parser.add_argument(
    "-a",
    "--analyze",
    action="store_true",
    help="Esegue solo l'analisi mostrando i valori I, LRA e TP senza creare file",
)
parser.add_argument(
    "--lra",
    type=float,
    default=9.0,
    help="Imposta il valore target di LRA (default: 9.0)",
)
parser.add_argument(
    "-k",
    "--keep",
    action="store_true",
    help="Mantiene i file originali invece di eliminarli dopo la normalizzazione",
)
parser.add_argument(
    "files",
    nargs="*",
    help="File video da elaborare (default: cartella corrente)",
)
args = parser.parse_args()

# variables
extensions = [".mp4", ".mkv", ".avi", ".ts", ".mov", ".flv"]
video_files = args.files
analyze_only = args.analyze
keep_originals = args.keep

# target loudnorm parameters
target_i = -21
target_lra = args.lra
target_tp = -1.5

# use half of available CPU cores (minimum 1)
total_cores = os.cpu_count() or 2
max_workers = max(1, total_cores // 2)

# synchronization & tracking
print_lock = threading.Lock()
state_lock = threading.Lock()
active_procs = set()
temp_files = set()
failed_files = []
interrupted = False
processing_started = False
inhibit_proc = None


# cleanup handler on Ctrl+C or SIGTERM
def cleanup_and_exit(signum=None, frame=None):
    global interrupted
    interrupted = True

    if inhibit_proc:
        inhibit_proc.terminate()

    if not processing_started:
        subprocess.run(["stty", "sane"], stderr=subprocess.DEVNULL)
        print(f"\n{orange}  Operazione annullata.{reset}")
        os._exit(0)

    with print_lock:
        print(
            f"\n{orange}  ‼ Interruzione rilevata. Arresto processi e pulizia file temporanei...{reset}"
        )

    with state_lock:
        for proc in list(active_procs):
            try:
                proc.kill()
            except Exception:
                pass

        for tmp in list(temp_files):
            if os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except Exception:
                    pass

    subprocess.run(["stty", "sane"], stderr=subprocess.DEVNULL)
    os._exit(130)


# ascolta i segnali di interruzione
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, cleanup_and_exit)


# check if ffmpeg and ffprobe are installed
if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
    print(
        f"{red}  Errore: ffmpeg o ffprobe non sono installati o non sono nel PATH.{reset}"
    )
    sys.exit(1)

if analyze_only:
    print(
        f"{cyan}  ======== Modalità solo analisi. NON verrà eseguita la normalizzazione. ========{reset}\n"
    )

# if no arguments search in current directory
if len(video_files) == 0:
    video_files = os.listdir()

# filter only existing video files (excludes _norm and _temp_processing)
video_files = [
    file
    for file in video_files
    if os.path.isfile(file)
    and os.path.splitext(file)[1].lower() in extensions
    and "_temp_processing" not in file
    and (
        analyze_only
        or not re.search(
            r"_norm(?:[^a-zA-Z]|$)", os.path.splitext(file)[0], re.IGNORECASE
        )
    )
]

# check if there are files
if len(video_files) == 0:
    print(
        f"{orange}  Non sono stati trovati file video validi o non già normalizzati.{reset}"
    )
    sys.exit(0)

# sort files by name
video_files.sort(key=str.lower)

# actual parallel workers (never greater than number of files)
active_workers = min(len(video_files), max_workers)

# show found files
action = f"{cyan}analizzare{reset}" if analyze_only else f"{magenta}normalizzare{reset}"
print(
    f"  {white}Trovati {len(video_files)} file video da {action}"
    f" (processi paralleli: {cyan if analyze_only else magenta}{active_workers}{white}/{total_cores}):\n"
)
print(yellow + "    " + "\n    ".join(video_files) + reset)

# ask for confirmation only when normalizing (default = Yes)
if not analyze_only:
    msg_del = (
        f"{green}verranno mantenuti"
        if keep_originals
        else f"{orange}verranno cestinati a fine lavoro"
    )
    print(f"\n  {orange}Nota:{white} i file originali {msg_del}.{reset}")
    print(f"  {white}Vuoi procedere? [S/n]: {reset}", end="", flush=True)
    answer = input().strip().lower()

    if answer not in ["", "s", "si", "sì"]:
        print(f"{orange}  Operazione annullata.{reset}\n")
        sys.exit(0)

print()

# start systemd-inhibit in background detached from TTY
if shutil.which("systemd-inhibit"):
    # fmt: off
    inhibit_proc = subprocess.Popen(["systemd-inhibit", "--what=sleep", "--who=normalize.py", "--why=Normalizzazione parallela con FFmpeg", "sleep", "infinity"
    ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    # fmt: on


def run_tracked_process(cmd):
    """Esegue un sottoprocesso registrandolo per poterlo uccidere subito in caso di Ctrl+C."""
    if interrupted:
        return -1, "", ""
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    with state_lock:
        active_procs.add(proc)
    try:
        stdout, stderr = proc.communicate()
        return proc.returncode, stdout, stderr
    finally:
        with state_lock:
            active_procs.discard(proc)


def get_sample_rate(file):
    # fmt: off
    cmd = [ "ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_rate", "-of", "default=noprint_wrappers=1:nokey=1", file,
    ]
    # fmt: on
    returncode, stdout, _ = run_tracked_process(cmd)
    rate = stdout.strip()
    return rate if returncode == 0 and rate.isdigit() else "48000"


def move_to_trash(path):
    """Sposta il file nel cestino usando 'trash' o 'gio trash'. Non elimina mai definitivamente."""
    if not os.path.exists(path):
        return False

    for cmd in (["trash", path], ["gio", "trash", path]):
        if shutil.which(cmd[0]):
            res = subprocess.run(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if res.returncode == 0:
                return True

    with print_lock:
        print(
            f"  {orange}Avviso: impossibile spostare nel cestino '{os.path.basename(path)}', il file è stato mantenuto.{reset}"
        )
    return False


def process_file(file):
    if interrupted:
        return False

    base, ext = os.path.splitext(file)
    json_file = f"{base}.json"
    stats = None

    # 1. Prova a caricare l'analisi da un file .json esistente
    if os.path.isfile(json_file):
        try:
            with open(json_file, "r", encoding="utf-8") as jf:
                cached = json.load(jf)
            if (
                cached.get("target_i") == target_i
                and cached.get("target_lra") == target_lra
                and cached.get("target_tp") == target_tp
                and "stats" in cached
            ):
                stats = cached["stats"]
                with print_lock:
                    print(
                        f"  {cyan}Analisi caricata da JSON:{yellow} {json_file}{reset}\n    {white}I:{orange} {stats['input_i']} LUFS{reset}  |  {white}LRA:{orange} {stats['input_lra']} LU{reset}  |  {white}TP:{orange} {stats['input_tp']} dBTP{reset}"
                    )
        except Exception:
            stats = None

    # 2. Se non c'è un JSON valido, esegui il Passaggio 1 con FFmpeg
    if stats is None:
        with print_lock:
            print(f"  {cyan}Analisi del file:{yellow} {file}{reset}")
        # fmt: off
        cmd_pass1 = ["ffmpeg", "-hide_banner", "-i", file, "-af", f"loudnorm=I={target_i}:LRA={target_lra}:TP={target_tp}:print_format=json", "-vn", "-sn", "-dn", "-f", "null", os.devnull,
        ]
        # fmt: on
        rc1, _, stderr1 = run_tracked_process(cmd_pass1)
        if interrupted:
            return False

        json_match = re.search(r"\{[\s\S]*?\}", stderr1)

        if rc1 != 0 or not json_match:
            with print_lock:
                print(f"  {red}Errore analisi:{yellow} {file}{reset}")
            with state_lock:
                failed_files.append(file)
            return False

        stats = json.loads(json_match.group(0))

        # Salva in modo atomico il risultato nel file .json quando usi -a
        if analyze_only or keep_originals:
            cache_data = {
                "target_i": target_i,
                "target_lra": target_lra,
                "target_tp": target_tp,
                "stats": stats,
            }
            tmp_json = f"{json_file}.tmp"
            with open(tmp_json, "w", encoding="utf-8") as jf:
                json.dump(cache_data, jf, indent=2)
            os.replace(tmp_json, json_file)

        # Mostra i valori rilevati solo quando l'analisi è stata appena eseguita
        with print_lock:
            saved_note = (
                f" {cyan}(salvato in {os.path.basename(json_file)}){reset}"
                if analyze_only
                else ""
            )
            print(
                f"  {white}Analisi completata:{yellow} {file}{saved_note}\n    {white}I:{orange} {stats['input_i']} LUFS{reset}  |  {white}LRA:{orange} {stats['input_lra']} LU{reset}  |  {white}TP:{orange} {stats['input_tp']} dBTP{reset}"
            )

    # Se è attivo -a, termina qui
    if analyze_only:
        return True

    # --- PASS 2: Linear normalization on temporary file ---
    temp_file = f"{base}_temp_processing{ext}"

    if os.path.basename(base).endswith("__"):
        final_file = f"{base}norm{ext}"
    else:
        final_file = f"{base}_norm{ext}"

    sample_rate = get_sample_rate(file)

    with state_lock:
        temp_files.add(temp_file)

    with print_lock:
        print(f"  {magenta}Normalizzazione del file:{yellow} {file}{reset}")

    loudnorm_pass2 = (
        f"loudnorm=I={target_i}:LRA={target_lra}:TP={target_tp}:"
        f"measured_I={stats['input_i']}:"
        f"measured_LRA={stats['input_lra']}:"
        f"measured_TP={stats['input_tp']}:"
        f"measured_thresh={stats['input_thresh']}:"
        f"offset={stats['target_offset']}:"
        f"linear=true:print_format=summary"
    )
    # fmt: off
    cmd_pass2 = ["ffmpeg", "-hide_banner", "-y", "-i", file, "-c:v", "copy", "-af", loudnorm_pass2, "-ar", sample_rate, "-c:a", "aac", "-b:a", "192k", temp_file,
    ]
    # fmt: on
    rc2, _, stderr2 = run_tracked_process(cmd_pass2)
    if interrupted:
        return False

    if rc2 == 0 and os.path.exists(temp_file):
        os.replace(temp_file, final_file)
        with state_lock:
            temp_files.discard(temp_file)

        # Sposta l'originale e l'eventuale cache .json nel cestino se non è attivo --keep
        if not keep_originals:
            if os.path.abspath(final_file) != os.path.abspath(file):
                move_to_trash(file)
            if os.path.exists(json_file):
                move_to_trash(json_file)

        with print_lock:
            print(f"  {green}Terminato:{yellow} {file}{green} -> {final_file}{reset}")
        return True
    else:
        if os.path.exists(temp_file):
            os.remove(temp_file)
        with state_lock:
            temp_files.discard(temp_file)
            failed_files.append(file)

        err_msg = stderr2.splitlines()[-1] if stderr2 else ""
        with print_lock:
            print(
                f"  {red}Errore normalizzazione:{yellow} {file}{white} ({err_msg}){reset}"
            )
        return False


# Parallel execution
processing_started = True
completed = 0
with ThreadPoolExecutor(max_workers=active_workers) as executor:
    futures = [executor.submit(process_file, file) for file in video_files]
    for future in as_completed(futures):
        if future.result():
            completed += 1

if inhibit_proc:
    inhibit_proc.terminate()

subprocess.run(["stty", "sane"], stderr=subprocess.DEVNULL)

end_action = "analizzati" if analyze_only else "normalizzati"
print(
    f"\n  {cyan if analyze_only else magenta}Elaborazione terminata! ({completed}/{len(video_files)} file {end_action}){reset}"
)

# Summary of failed files
if failed_files:
    print(f"\n  {red}Elenco dei file corrotti o falliti e saltati:{reset}")
    for f in sorted(failed_files, key=str.lower):
        print(f"    {orange}• {f}{reset}")
    sys.exit(1)
