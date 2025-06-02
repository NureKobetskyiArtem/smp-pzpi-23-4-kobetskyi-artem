#!/bin/bash

VER="1.0"
SRC_ENC="cp1251"
DST_ENC="UTF-8"
TMP_GRP_FILE="grps.tmp"
silent=0

usage() {
    echo "Синтаксис: ${0##*/} [--help | --version] | [[-s|--silent] [група] файл.csv]"
    echo "Перетворює розклад із CIST у формат для Google Calendar."
    exit 0
}

version_info() {
    echo "${0##*/} v$VER"
    exit 0
}

ask_csv_file() {
    echo "Оберіть CSV-файл:"
    readarray -t files < <(ls TimeTable_??_??_20??.csv 2>/dev/null | sort -t_ -k4,4n -k3,3n -k2,2)
    [[ ${#files[@]} -eq 0 ]] && echo "Файли не знайдено!" >&2 && exit 1
    select f in "${files[@]}"; do
        [[ -n "$f" ]] && chosen_file="$f" && break
    done
}

grab_groups() {
    readarray -t all_grps < <(iconv -f "$SRC_ENC" -t "$DST_ENC" "$chosen_file" | grep -o 'ПЗПІ-[0-9]\+-[0-9]\+' | sort -u)
    [[ ${#all_grps[@]} -eq 0 ]] && echo "Групи не виявлено у файлі." >&2 && return 1
    printf "%s\n" "${all_grps[@]}" > "$TMP_GRP_FILE"
    return 0
}

is_group_valid() {
    grab_groups || return 0
    grep -q "^$grp$" "$TMP_GRP_FILE"
}

choose_group() {
    grab_groups || return 1
    mapfile -t group_list < "$TMP_GRP_FILE"
    if [[ ${#group_list[@]} -eq 1 ]]; then
        grp="${group_list[0]}"
        echo "Вибрана група: $grp"
    else
        echo "Виберіть групу:"
        select g in "${group_list[@]}"; do
            [[ -n "$g" ]] && grp="$g" && break
        done
    fi
}

normalize_file() {
    iconv -f "$SRC_ENC" -t "$DST_ENC" "$chosen_file" > "$output_file" || {
        echo "Помилка при перекодуванні." >&2
        exit 1
    }
    sed -i '' 's/\r/\n/g' "$output_file"
}

export_to_google_csv() {
    tmp1=$(mktemp)
    tmp2=$(mktemp)

    awk -v G="$grp" '
    BEGIN { FS=","; OFS="\t" }
    NR==1 { next }

    function pad(date, time) {
        split(date, d, ".")
        split(time, t, ":")
        return sprintf("%04d%02d%02d%02d%02d", d[3], d[2], d[1], t[1], t[2])
    }

    function clean(s) {
        gsub(/^"|"$/, "", s)
        return s
    }

    {
        raw=$0
        match(raw, /"[0-3][0-9]\.[0-1][0-9]\.[0-9]{4}"/)
        if (RSTART==0) next

        header = substr(raw, 1, RSTART - 2)
        payload = substr(raw, RSTART)

        fcount = 0
        inq = 0
        field = ""
        for (i = 1; i <= length(payload); i++) {
            c = substr(payload, i, 1)
            if (c == "\"") inq = !inq
            else if (c == "," && !inq) {
                cols[++fcount] = field
                field = ""
            } else {
                field = field c
            }
        }
        cols[++fcount] = field

        for (j = 1; j <= fcount; j++) cols[j] = clean(cols[j])
        if (fcount < 12) next

        if (header ~ /(ПЗПІ-[0-9]+-[0-9]+)/) {
            match(header, /(ПЗПІ-[0-9]+-[0-9]+)/)
            found = substr(header, RSTART, RLENGTH)
        }
        if (found != G) next

        header = substr(header, RSTART + RLENGTH)
        gsub(/^[[:space:]]+/, "", header)
        subj = header
        gsub(/^"|"$/, "", subj)
        gsub(/^- /, "", subj)

        note = cols[11]
        typ = "Інше"
        if (note ~ /Лб/) typ = "Лб"
        else if (note ~ /Лк/) typ = "Лк"
        else if (note ~ /Пз/) typ = "Пз"
        else if (note ~ /Екз/i) typ = "Екз"

        key = pad(cols[1], cols[2])
        print subj, typ, cols[1], cols[2], cols[3], cols[4], note, key
    }' "$output_file" > "$tmp2"

    sort -t $'\t' -k8,8 "$tmp2" > "$tmp1"

    echo "Subject,Start Date,Start Time,End Date,End Time,Description" > "$output_file"

    awk -F'\t' -v s="$silent" '
    BEGIN { OFS = "," }

    function format_d(d) {
        split(d, a, ".")
        return sprintf("%02d/%02d/%04d", a[2], a[1], a[3])
    }

    function format_t(t) {
        split(t, hm, ":")
        h = hm[1] + 0
        m = hm[2]
        p = (h >= 12) ? "PM" : "AM"
        if (h == 0) h = 12
        else if (h > 12) h -= 12
        return sprintf("%02d:%s %s", h, m, p)
    }

    {
        k1 = $1 "_" $2
        k2 = $3 "_" $7

        if ($2 == "Лб") {
            if (!(k2 in labmap)) {
                count[k1]++
                labmap[k2] = count[k1]
            }
            n = labmap[k2]
        } else {
            count[k1]++
            n = count[k1]
        }

        subj_full = $1 "; №" n
        sd = format_d($3)
        st = format_t($4)
        ed = format_d($5)
        et = format_t($6)
        dsc = $7

        line = sprintf("\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"", subj_full, sd, st, ed, et, dsc)
        print line >> "'$output_file'"
        if (s != 1) print line
    }' "$tmp1"

    rm -f "$tmp1" "$tmp2"
}

while [[ "$1" =~ ^- ]]; do
    case "$1" in
        --help) usage ;;
        --version) version_info ;;
        -s|--silent) silent=1; shift ;;
        *) break ;;
    esac
done

grp="$1"
chosen_file="$2"

if [[ -z "$chosen_file" || -z "$grp" ]]; then
    [[ -z "$chosen_file" ]] && ask_csv_file
    [[ ! -f "$chosen_file" ]] && echo "Файл '$chosen_file' не знайдено." >&2 && exit 1
    dt=$(echo "$chosen_file" | grep -oE '[0-9]{2}_[0-9]{2}_[0-9]{4}')
    [[ -z "$dt" ]] && dt="unknown"
    output_file="Google_TimeTable_${dt}.csv"
    normalize_file
    choose_group
else
    [[ ! -f "$chosen_file" ]] && echo "Файл '$chosen_file' не знайдено." >&2 && exit 1
    dt=$(echo "$chosen_file" | grep -oP '\d{2}_\d{2}_\d{4}')
    [[ -z "$dt" ]] && dt="unknown"
    output_file="Google_TimeTable_${dt}.csv"
    normalize_file
    if ! is_group_valid; then
        echo "Групу '$grp' не знайдено. Виберіть іншу:"
        choose_group
    fi
fi

export_to_google_csv
rm -f "$TMP_GRP_FILE"