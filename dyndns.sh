#!/bin/bash

api_host="https://api.digitalocean.com/v2"
sleep_interval=${SLEEP_INTERVAL:-300}
remove_duplicates=${REMOVE_DUPLICATES:-"false"}
use_ipv6=${USE_IPV6:-"false"}

services=(
    "ifconfig.co"
    "ipinfo.io/ip"
    "ifconfig.me"
)
ipv6_services=(
    "icanhazip.com"
    "ifconfig.co"
    "ipinfo.io/ip"
    "ifconfig.me"
)

[[ "${use_ipv6}" = "true" ]] && domain_record_type="AAAA" || domain_record_type="A"

die() {
    echo "$1"
    exit 1
}

test -f "$DIGITALOCEAN_TOKEN_FILE" && DIGITALOCEAN_TOKEN="$(cat $DIGITALOCEAN_TOKEN_FILE)"
test -z $DIGITALOCEAN_TOKEN && die "DIGITALOCEAN_TOKEN not set!"
test -z $DOMAIN && die "DOMAIN not set!"
test -z $NAME && die "NAME not set!"

dns_list="$api_host/domains/$DOMAIN/records"

while ( true ); do
    domain_records=$(curl -s -X GET \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
        $dns_list"?per_page=200")

    if [[ "${use_ipv6}" = "true" ]]; then
        for service in ${ipv6_services[@]}; do
            echo "Trying with $service..."

            ip="$(curl -6 -s $service)"
            test -n "$ip" && break
        done
    else
        for service in ${services[@]}; do
            echo "Trying with $service..."

            ip="$(curl -s $service | grep '[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}')"
            test -n "$ip" && break
        done
    fi

    echo "Found IP address $ip"

    if [[ -n $ip ]]; then
        # disable glob expansion
        set -f

        for sub in ${NAME//;/ }; do
            record_id=$(echo $domain_records| jq ".domain_records[] | select(.type == \"$domain_record_type\" and .name == \"$sub\") | .id")
            record_data=$(echo $domain_records| jq -r ".domain_records[] | select(.type == \"$domain_record_type\" and .name == \"$sub\") | .data")

            if [ $(echo "$record_id" | wc -l) -ge 2 ]; then :
                if [[ "${remove_duplicates}" == "true" ]]; then :
                    echo "'$sub' domain name has duplicate DNS records, removing duplicates"
                    record_id_to_delete=$(echo "$record_id"| tail -n +2)
                    record_id=$(echo "$record_id"| head -1)
                    record_data=$(echo "$record_data"| head -1)

                    while IFS= read -r line; do
                        curl -s -X DELETE \
                            -H "Content-Type: application/json" \
                            -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
                            "$dns_list/$line" &> /dev/null
                    done <<< "$record_id_to_delete"
                else :
                    echo "Unable to update '$sub' domain name as it has duplicate DNS records. Set REMOVE_DUPLICATES='true' to remove them."
                    continue
                fi
            fi

            # re-enable glob expansion
            set +f

            data="{\"type\": \"$domain_record_type\", \"name\": \"$sub\", \"data\": \"$ip\"}"
            url="$dns_list/$record_id"

            if [[ -z $record_id ]]; then
                echo "No record found with '$sub' domain name. Creating record, sending data=$data to url=$url"

                new_record=$(curl -s -X POST \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
                    -d "$data" \
                    "$url")

                record_data=$(echo $new_record| jq -r ".data")
            fi

            if [[ "$ip" != "$record_data" ]]; then
                echo "existing DNS record address ($record_data) doesn't match current IP ($ip), sending data=$data to url=$url"

                curl -s -X PUT \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
                    -d "$data" \
                    "$url" &> /dev/null
            else
                echo "existing DNS record address ($record_data) did not need updating"
            fi
        done
    else
        echo "IP wasn't retrieved within allowed interval. Will try $sleep_interval seconds later.."
    fi

    sleep $sleep_interval
done
