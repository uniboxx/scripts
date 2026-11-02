#!/usr/bin/env zsh

# Autore: Davide Pedrotti
# Data creazione: 18/10/2026
# Ultima modifica: 02/11/2026

# Descrizione: Converte l'audio dei file video in aac e normalizza l'audio con il valore della variabile db.

# Nota: Lo script usa sintassi zsh per cui occorre aver installato zsh.
# Utilizzo: normalize <flags> <files> | default tutti i files nella cartella corrente con estensioni definite in extensions.
# aggiungere il flag -a per abilitare la funzionalità solo analisi | aggiungere il flag --lra <valore> per impostare il valore di lra

# resetta zsh
emulate -L zsh
# Attiva il sistema di completamento (obbligatorio in Zsh per abilitare il tasto TAB)
autoload -Uz compinit && compinit -i
# Abilita globbing
setopt EXTENDED_GLOB NULL_GLOB

if [[ -z "$SCRIPT_INHIBITED" ]]; then
    export SCRIPT_INHIBITED=1
    # Protegge lo sleep hardware e passa i parametri in modo sicuro
    exec systemd-inhibit --what=sleep --who="normalize.zsh" --why="Normalizzazione parallela con FFmpeg" "$0" "${@:-}"
fi

# Funzione di arresto forzato
pulisci_ed_esci() {
    # Disattiva temporaneamente il trap per evitare cicli infiniti
    trap - INT TERM EXIT
    print -P "\n${c_red}‼ Interruzione totale rilevata. Arresto immediato di tutte le conversioni...${reset}"
    
    # Rimuove in sicurezza solo i file temporanei legati a questo processo
    rm -f ./*_temp_processing.* 2>/dev/null
    
    # Invia il segnale TERM a TUTTI i processi del gruppo di questo script (subshell comprese)
    kill -TERM -$$ 2>/dev/null
    exit 130
}
# Cattura il CTRL+C sia nello script principale che nei processi figli
trap pulisci_ed_esci INT TERM

# Colori
export bold=$'\033[1m'
export reset=$'\033[0m'
export c_white=$'\033[1;37m'
export c_red=$'\033[1;31m'
export c_cyan=$'\033[1;36m'
export c_green=$'\033[1;32m'
export c_yellow=$'\033[1;33m'
export c_magenta=$'\033[1;35m'
export c_orange=$'\033[1;38;2;255;153;0m'

# Variabili 
# opzioni per ffmpeg
typeset db="21"
typeset lra="11"
typeset tp="1.5"
typeset target_linear="false"
typeset only_analyze="false"
# opzioni passate allo script tramite flag
local -A opts
typeset -a flag_analyze
zparseopts -D -A opts -lra: a=flag_analyze
if (( ${#flag_analyze} > 0 )); then
    only_analyze="true"
    print -P "${c_orange}======== Modalità solo analisi. NON verrà eseguite la normalizzazione. ========${reset}"
fi
if (( ${+opts[--lra]} )); then
    lra=$opts[--lra]
    print -P "${c_orange}Valore lra impostato a ${lra}${reset}"
fi

typeset -a extensions=(mp4 mkv avi mov flv ts)
files="$@"
typeset -a files_list=()
typeset -a valid_list=()
typeset -a not_found_list=()
typeset -a already_normalized_list=()
typeset -a invalid_list=()


# Funzioni
function sanitize_paths() {
    # Riceve l'intera stringa racchiusa tra doppie virgolette
    local raw_input="$1"
    
    # 1. RIMOZIONE SPAZI MULTIPLI (Split & Join in una riga)
    # ${(z)raw_input} analizza la stringa e la divide rispettando gli spazi protetti (es. "file con spazi.mp4")
    # ${(j: :)...} riunisce i pezzi usando un UNICO spazio come separatore, eliminando i doppi spazi
    local clean_string="${(j: :)${(z)raw_input}}"

    # Se dopo la pulizia la stringa è vuota, azzera l'array ed esce
    if [[ -z "${clean_string//[[:space:]]/}" ]]; then
        files_list=()
        return 0
    fi

    # 2. Creazione dell'array (separando sull'unico spazio rimasto)
    files_list=( ${(s: :)clean_string} )
    
    # 3. Ciclo di conversione in percorsi assoluti
    for i in {1..${#files_list}}; do
        if [[ "${files_list[i]}" == \~/* ]]; then
            files_list[i]="${HOME}${files_list[i]#\~}"
        fi
        files_list[i]="${files_list[i]:A}"
    done
    
    # 4. Espansione dei caratteri jolly (come *)
    files_list=( $~files_list )
}

function check_files() {
    # Resetta gli array globali prima di iniziare
    not_found_list=()
    already_normalized_list=()
    valid_list=()
    invalid_list=()

    # ciclo di controllo
    for file in "${files_list[@]}"; do
        # 1. Se il file NON esiste sul disco
        if [[ ! -e "$file" ]]; then
            not_found_list+=("$file")
        else
            # 2. Se esiste, controlla estensione
            local ext="${(L)file##*.}"
            if [[ -n "${extensions[(r)$ext]}" ]]; then
                # 3. Se già normalizzato, lo salta
                if [[ "${file:t:r}" == *_norm ]]; then
                    already_normalized_list+=( "$file" )
                else
                    # 4. Se non normalizzato, lo normalizza
                    valid_list+=( "$file" )
                fi
            else
                # 5. Se non supportato, lo salta
                invalid_list+=( "$file" )
            fi
        fi
    done

    # Restituisce lo stato (0 se ci sono file da elaborare, 1 se è vuoto)
    (( ${#valid_list} > 0 ))
}

function ask4files() {
    # Se l'utente ha passato argomenti da riga di comando
    if [[ -n "$files" ]]; then
        sanitize_paths "$files"
        check_files
        
        # Popoliamo vared solo con i file validi per la verifica dell'utente
        files="${(j: :)valid_list}"
    else
        files=""
    fi

    # Ciclo di interazione con l'utente
    while true; do
        vared -p "${c_white}Files da elaborare (default: tutti i files ${(j:,:)extensions} nella cartella corrente): ${reset}" files
        # Trim files
        files="${(j: :)${(z)files}}"

        # Caso di default: Invio premuto senza digitare nulla
        if [[ -z "${files//[[:space:]]/}" ]]; then
            local -a default_glob=()
            for ext in "${extensions[@]}"; do
                default_glob+=( *.$ext )
            done
            sanitize_paths "${(j: :)default_glob}"
        else
            sanitize_paths "$files"
        fi

        check_files

        # controlla se ci sono files validi
        if (( ${#valid_list} == 0 )); then
            print -P "\n${c_red}✘ Errore: Nessun file valido trovato per l'input inserito. Riprova.${reset}\n"
            files="" 
            continue
        fi

        # controllo se ci sono problemi con l'input inserito
        if (( ${#not_found_list} > 0 || ${#invalid_list} > 0 )); then
            print -P "\n${c_yellow}! Segnalazione problemi di input (alcuni file verranno scartati):${reset}"
            # elenco files non trovati
            if (( ${#not_found_list} > 0 )); then
                print -P "  - ${c_cyan}I seguenti file ${c_red}NON ESISTONO ${c_cyan}sul disco:${reset}"
                for file in "${not_found_list[@]}"; do
                    print -P "    ${c_orange}• $file${reset}"
                done
            fi
            # elenco files non supportati
            if (( ${#invalid_list} > 0 )); then
                print -P "  - ${c_cyan}I seguenti file ${c_red}NON SONO VIDEO VALIDI${c_cyan} (${extensions[*]}):${reset}"
                for file in "${invalid_list[@]}"; do
                    print -P "    ${c_orange}• $file${reset}"
                done
            fi
            print -P "  - ${c_cyan}I seguenti file ${c_green}SONO VIDEO VALIDI:${reset}"
            for file in "${valid_list[@]}"; do
                print -P "    ${c_green}• $file${reset}"
            done
            print ""

            # Chiede se proseguire con i file rimanenti
            local response=""
            vared -p "${c_white}Proseguire con i file video validi? (y/N): ${c_orange}" response
            print -nP "${reset}"
            response="${response//[[:space:]]/}"
            if [[ -z "$response" || "$response" != [Yy] ]]; then
                echo $response
                print -nP "\n${c_cyan}Inserisci nuovamente i file.${reset}\n"
                continue
            fi
        fi
        files_list=( "${valid_list[@]}" )
        break
    done
}

function normalize_file() {
    local file="$1"
    [[ -z "$file" ]] && return

    # Definiamo un'intestazione breve per distinguere i log paralleli
    local tag="${c_yellow}$file:t${reset}"

    # Estrae l'estensione originale (es. mp4, mkv, avi)
    local ext="${(L)file##*.}"
    # Estrae il nome del file senza l'estensione
    local filename="${file%.*}"
    # Assegna un nome temporaneo per il file in elaborazione
    local target_file="${filename}_temp_processing.${ext}"

    # Passaggio 1: Analisi
    print -P "${c_cyan}----------------------------------------"
    print "Passaggio 1: Analisi di $tag"

    local stats
    stats=$(ffmpeg -i "$file" -af loudnorm=I=-${db}:TP=-${tp}:LRA=${lra}:print_format=json -f null - 2>&1)

    # Se FFmpeg è stato interrotto (exit code 130, o comunque > 128), killa il padre e ferma la subshell
    if (( $? > 128 )); then
        kill -INT $$ 2>/dev/null
        return 130
    fi

    local measured_i=$(echo "$stats" | sed -n 's/.*"input_i" : "\([^"]*\)".*/\1/p')
    local measured_tp=$(echo "$stats" | sed -n 's/.*"input_tp" : "\([^"]*\)".*/\1/p')
    local measured_lra=$(echo "$stats" | sed -n 's/.*"input_lra" : "\([^"]*\)".*/\1/p')
    local measured_thresh=$(echo "$stats" | sed -n 's/.*"input_thresh" : "\([^"]*\)".*/\1/p')

    # Controllo di sicurezza: se la variabile è vuota, stampa i log di FFmpeg ed esce
    if [[ -z "$measured_i" ]]; then
        print "${c_red}Errore: Impossibile analizzare l'audio di $tag. ${c_cyan}Ecco l'output di FFmpeg:${reset}"
        echo "$stats" | tail -n 25
        print "${c_red}----------------------------------------${reset}"
        return 1
    fi

    # Mostra i valori rilevati a terminale
    print -P "${c_cyan}----------------------------------------${reset}"
    print -P "${c_cyan}Analisi di $tag ${c_cyan}completata.${reset}"
    print "${c_white}Valori rilevati -> I: ${c_orange}$measured_i${c_white} | TP: ${c_orange}$measured_tp${c_white} | LRA: ${c_orange}$measured_lra${c_white} | Thresh: ${c_orange}$measured_thresh${reset}"

    # Se viene passato il flag -a, si ferma qui ed evita il passaggio 2
    if [[ "$only_analyze" == "true" ]]; then
        return 0
    fi

    # Passaggio 2: Normalizzazione
    print -P "${c_magenta}----------------------------------------${reset}"
    print "${c_magenta}Passaggio 2: Normalizzazione di $tag"

    # Esegue FFmpeg sul file di destinazione (target_file)
    if ffmpeg -y -i "$file" -af "loudnorm=I=-${db}:TP=-${tp}:LRA=${lra}:measured_i=${measured_i}:measured_tp=${measured_tp}:measured_lra=${measured_lra}:measured_thresh=${measured_thresh}:linear=${target_linear}" -c:v copy -c:a aac -b:a 192k "$target_file" >/dev/null 2>&1; then
        # Controlla se il file == __
        local final_file=""
        if [[ "$filename:t" == *__ ]]; then
            final_file="${filename}norm.${ext}"
        else
            final_file="${filename}_norm.${ext}"
        fi

        # 2. Rinomina il file temporaneo usando la nuova variabile
        mv "$target_file" "$final_file"

        # 3. CONDIZIONE DI SICUREZZA:
        # Rimuove il file di origine SOLO se il file finale ha un nome diverso
        if [[ "$final_file" != "$file" ]]; then
            rm "$file"
        fi
        
        print -P "${c_green}----------------------------------------${reset}"
        print -P "✔ $tag ${c_green}completato con successo.${reset}"
    else
        print -P "${c_red}----------------------------------------${reset}"
        print -P "${c_red}✘ Errore durante l'elaborazione di: $tag."
        # Rimuove il file temporaneo/parziale se è stato creato per non lasciare spazzatura
        [[ -f "$target_file" ]] && rm "$target_file"
    fi
}

########################################
# FLUSSO PRINCIPALE DI ESECUZIONE (MAIN)
########################################

# Controlla se l'utente ha premuto invio senza inserire nulla. 
if [[ -z "$files" ]]; then
    # prende tutti i files con estensioni specificate
    local -a default_glob=()
    for ext in "${extensions[@]}"; do
        default_glob+=( *.$ext )
    done

    # Sanifichiamo i file trovati per averli in percorsi assoluti
    sanitize_paths "${(j: :)default_glob}"
    
    if (( ${#files_list} == 0 )); then
        print -P "\n${c_red}! Warning: Nessun file video ${(j:,:)extensions} trovato nella cartella corrente.${reset}\n"
        exit 0
    fi

    # Eseguiamo lo smistamento (i file _norm vanno in already_normalized_list)
    check_files

    # SE NON CI SONO FILE NUOVI DA ELABORARE (valid_list è vuota)
    if (( ${#valid_list} == 0 )); then
        if (( ${#already_normalized_list} > 0 )); then
            print -P "\n${c_yellow}! Tutti i file video nella cartella sono GIA' NORMALIZZATI (*_norm).${reset}\n"
        else
            print -P "\n${c_red}! Attenzione: Nessun file idoneo alla normalizzazione trovato.${reset}\n"
        fi
        exit 0
    fi

    # Se ci sono file nuovi validi, procediamo alla richiesta di conferma
    files_list=( "${valid_list[@]}" )

    print -P "\n${c_cyan}I seguenti file NUOVI verranno elaborati:${reset}"
    for file in "${files_list[@]}"; do
        print -P "  ${c_yellow}• $file:t${reset}"
    done
    print ""

    local answer="Y"
    vared -p "${c_white}Procedere con la normalizzazione? (${c_green}Y/n${reset}): " answer
    answer="${answer//[[:space:]]/}"
    if [[ -n "$answer" && "$answer" != [Yy] ]]; then
        print -P "${c_cyan}Operazione annullata.${reset}"
        exit 0
    fi
else
    ask4files
fi

# ===========================
# MOTORE DI PARALLELIZZAZIONE
# ===========================
local num_jobs=3
typeset -A running_pids=()

print -P "\n${c_white}🚀 Avvio elaborazione parallela ${c_cyan}(max $num_jobs file simultanei)...${reset}\n"

for file in "${files_list[@]}"; do
    # 1. Avvia la funzione in background
    normalize_file "$file" &
    # 2. Cattura il PID dell'ultimo processo appena lanciato ($!)
    local pid=$!
    running_pids[$pid]=$file

    # 3. Se abbiamo raggiunto il limite di 2 job attivi, aspettiamo che uno si liberi
    while (( ${#running_pids} >= num_jobs )); do
        # Controlliamo ciclicamente se i processi attivi sono ancora vivi
        for pid_active in ${(k)running_pids}; do
            # kill -0 controlla se il processo esiste senza fargli nulla
            if ! kill -0 $pid_active 2>/dev/null; then
                # Se il processo è morto, lo rimuoviamo dall'array per liberare un posto
                unset "running_pids[$pid_active]"
                break
            fi
        done
        # Aspetta una frazione di secondo prima del prossimo controllo per non sovraccaricare la CPU
        sleep 0.5
    done
done

# 4. Aspetta la conclusione degli ultimi file rimasti nella coda
wait

print -P "${c_white}========================================${reset}"
if [[ $only_analyze == "true" ]]; then 
    print -P "${c_cyan}Processo di analisi completato.${reset}"
else
    print -P "${c_magenta}Processo di normalizzazione completato. Livello medio db: ${c_yellow}${db}dB!${reset}"
fi
print -P "${c_white}========================================${reset}\n"

exit 0