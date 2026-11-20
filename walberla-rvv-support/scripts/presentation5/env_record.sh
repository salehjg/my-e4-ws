# presentation5: record the board's state next to every timing (sourced by the presentation5 timing scripts).
# presentation4's logs had only the load average, which is 2.0 on an idle board (D-state kernel threads), so
# other load, the clock and the temperature were invisible (docs/notes5, finding F21).
#   env_record   governor, current frequency of every core, temperatures, busy cores
#   busy_cores   one line: the cores busier than 3 % over 1 s, from two /proc/stat samples

busy_cores() {
    local a b
    a="$(grep -E '^cpu[0-9]' /proc/stat)"; sleep 1; b="$(grep -E '^cpu[0-9]' /proc/stat)"
    paste <(echo "${a}") <(echo "${b}") | awk '{
        n = (NF - 2) / 2; ta = 0; tb = 0
        for (i = 2; i <= n + 1; i++) ta += $i
        for (i = n + 3; i <= NF; i++) tb += $i
        ia = $5 + $6; ib = $(n + 6) + $(n + 7)                   # idle + iowait
        busy = (tb - ta) > 0 ? 100 * (1 - (ib - ia) / (tb - ta)) : 0
        if (busy > 3) s = s sprintf(" %s=%.0f%%", $1, busy)
    } END { print "busy cores (>3 % over 1 s):" (s == "" ? " none" : s) }'
}

env_record() {
    echo "   governor: $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | tr '\n' ' ')"
    echo "   frequency (kHz): $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
    local z t="" mc
    for z in /sys/class/thermal/thermal_zone*; do
        mc="$(cat "${z}/temp" 2>/dev/null)"; [[ "${mc}" =~ ^[0-9]+$ ]] && t+=" $(cat "${z}/type")=$(( mc / 1000 ))C"
    done
    echo "   temperatures:${t}"
    echo "   load: $(cut -d' ' -f1-3 /proc/loadavg) (2.00 when idle)"
    echo "   $(busy_cores)"
}
