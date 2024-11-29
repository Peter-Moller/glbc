#!/bin/bash

get_html_tables() {

    local HTMLReport
    # Remove nested tables
    HTMLReport=$(printf "%s" "$1" | \
        sed -n '/<section>/,/<\/section>/p' | \
        perl -pe 's/\n/NEWLINE/'| \
        perl -pe 's/<tr>(?:(?:(?!<\/?tr>).)*?<table.*?<\/table>.*?)<\/tr>//g' | \
        sed 's/NEWLINE/\n/g')

    # Get tables
    while IFS= read -r -d '' Table; do
        HTMLTables+=("$Table")
    done < <(python3 - <<EOF
import re

html_content = """$HTMLReport"""
table_pattern = re.compile(r'<table.*?</table>', re.DOTALL)
tables = table_pattern.findall(html_content)

for table in tables:
    print(table + '\0')

EOF
)

}

remove_html_tags() {
    local HTMLTable=$1

    echo "$HTMLTable" | grep -v "\<th" | \
                  sed -e 's/<\/tr>//g' \
                      -e 's/<\/td>//g' \
                      -e 's/<\/\?code>/\`/g' \
                      -e 's/<\/\?i>/\*/g' \
                      -e 's/<br>/br_tag/g' \
                      -e 's/<[^>]*>//g' \
                      -e 's/br_tag/<br>/g' \
                      -e 's/^[[:space:]]*$//g' \
                      -e 's/^[[:space:]]*//g' \
                      -e 's/|/\\|/g' \
                      -e '/^$/d'
}


create_md_report() {

    local Headers=("$1" "")
    local HTMLTable="$2"
    local RowsToInclude=("${@:3}")
    TableCells=()

    IFS=$'\n' read -r -d '' -a TableRows <<< "$(remove_html_tags "$HTMLTable")"

    for TableRow in "${TableRows[@]}"; do

        FirstColumn="${TableRow%%:*}:"
        SecondColumn="${TableRow#*:}"

        if [ ${#RowsToInclude[@]} -eq 0 ]; then # Include all table rows
            TableCells+=("$FirstColumn")
            TableCells+=("$SecondColumn")
        else
            for RowToInclude in "${RowsToInclude[@]}"; do
                if [[ "$RowToInclude:" == "$FirstColumn"* ]]; then
                    TableCells+=("$FirstColumn")
                    TableCells+=("$SecondColumn")
                fi
            done
        fi
    done

    for (( i=0; i<${#TableCells[@]}-1; i++ )); do
        if [[ "${TableCells[i],,}" == status*: ]]; then
            if [[ "${TableCells[i+1],,}" == *success* || "${TableCells[i+1],,}" == **ok** ]]; then
                TableCells[i+1]="<span class=\"inline-status-good\">${TableCells[i+1]}</span>"
            else
                TableCells[i+1]="<span class=\"inline-status-crit\">${TableCells[i+1]}</span>"
            fi
        fi
    done

    local MarkdownTable=""

    for Header in "${Headers[@]}"; do
        MarkdownTable+="| $Header "
    done
    MarkdownTable+="|\n"

    for Header in "${Headers[@]}"; do
        MarkdownTable+="|---"
    done
    MarkdownTable+="|\n"

    for ((i=0; i<${#TableCells[@]}; i+=2)); do
        MarkdownTable+="| ${TableCells[$i]} | ${TableCells[$i+1]} |\n"
    done

    printf "%b" "$MarkdownTable"
}