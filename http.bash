#!/bin/bash

function die () {
    echo "$2" 1>&2
    exit $1
}

url="$1"

url_re="^((https?)://)?([A-Za-z0-9.-]+)(:([0-9]+))?(/.*)?$"
if [[ "$url" =~ $url_re ]]; then
    scheme=${BASH_REMATCH[2]}
    host=${BASH_REMATCH[3]}
    port=${BASH_REMATCH[5]}
    path=${BASH_REMATCH[6]}
else
    die 1 "Bad URL"
fi

if [ "$scheme" = "" ]; then
    scheme="http"
fi

if [ "$host" = "" ]; then
    die 1 "Bad URL - no host specified"
fi

if [ "$port" = "" ]; then
   port=80
fi

dev_tcp_path="/dev/tcp/${host}/${port}"

exec 3<> ${dev_tcp_path}
exec_ret=$?
if [ "$exec_ret" != 0 ]; then
    die 1 exec_ret=$exec_ret
fi

printf "GET $path HTTP/1.1\r\nhost: %s\r\nConnection: close\r\n\r\n" "$host" >&3
read -u3
http_resp_re="^HTTP/([0-9.]+) +([0-9]+) +(.*)$"
if [[ "$REPLY" =~ $http_resp_re ]]; then
    version=${BASH_REMATCH[1]}
    resp_code=${BASH_REMATCH[2]}
    resp_msg=${BASH_REMATCH[3]}
else
    die 1 "Malformed HTTP response: $REPLY"
fi

if [ "$resp_code" != 200 ]; then
    die 1 "HTTP response $resp_code $resp_msg"
fi

printf -vCR "\r"
header_re="^([A-Za-z0-9-]+): (.*)${CR}?$" 
while read -u3; do
    if [ "$REPLY" = "" ] || [ "$REPLY" = "${CR}" ]; then
	break
    elif [[ "$REPLY" =~ $header_re ]]; then
	#echo "Header: name=${BASH_REMATCH[1]}, value=${BASH_REMATCH[2]}"
	:
    else
	die 1 "Malformed HTTP response header: \"$REPLY\""
    fi
done

cat < /dev/fd/3
