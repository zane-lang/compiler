# hotdis.sh PROFILE BINARY FUNCTION MIN DIV : hottest instructions, disassembled, count/DIV
H=$(dirname "$0")/memmove/hot.py
python3 $H $1 $3 80 | awk -v m=$4 '$2>=m && $1 ~ /^0x/' | sort -k1 | while read a c rest; do d=$(objdump -d --no-show-raw-insn --start-address=$a --stop-address=$((a+16)) $2 | grep -m1 "^ *${a#0x}:" | cut -f2-); printf "%8.2f %s %s\n" $(echo "$c/$5" | bc -l) "$a" "$d"; done
