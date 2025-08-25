# show a spinner while looking for the current SSID
wait_for_ssid() {
  local timeout="${1:-15}"
  local ssid=""
  local t=0
  local frames='|/-\'
  local i=0

  printf "Checking Wi-Fi for current SSID (up to %ss) " "$timeout" >&2
  while (( t < timeout )); do
    ssid="$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')"
    if [[ -n "$ssid" ]]; then
      printf "\rDetected SSID: %s%*s\n" "$ssid" 20 "" >&2
      echo "$ssid"
      return 0
    fi
    printf "\rChecking Wi-Fi %s " "${frames:i++%${#frames}:1}" >&2
    sleep 0.2
    ((t+=1))
  done
  printf "\rNo Wi-Fi SSID detected.%*s\n" 40 "" >&2
  echo ""
  return 1
}
