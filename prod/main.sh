#!/usr/bin/env bash

### validate variables ###

if [ -z $LINODE_API_TOKEN ];
  then
    echo "Missing variable: LINODE_API_TOKEN"
    exit 1
  elif [ -z $node_name ];
  then
    echo "Missing variable: node_name"
    exit 1
  elif [ -z $vlan_name ];
  then
    echo "Missing variable: vlan_name"
    exit 1
  elif [ -z $vlan_cidr ];
  then
    echo "Missing variable: vlan_cidr"
    exit 1
  else
    echo "All init variables exist, starting script"
fi

### declare functions ###

generate_ip () {
  # function parameters
  # get the first positional parameter
  cidr_block=$1
  # the rest of the positional parameters are the current IPs in use
  shift
  used_ips=("$@")

  # create derived variables
  cidr_network_identifier="${cidr_block#*/}"

  # convert used_ips to CIDR string list with /32 prefixes (e.g. 192.168.0.1/32,192.168.0.7/32,...)
  for ip in ${used_ips[@]}
  do
    ip_address_without_network="${ip%/*}"
    ip_exclude_list+="$ip_address_without_network/32,"
  done

  # remove trailing comma in the list
  ip_exclude_list=${ip_exclude_list%,}

  # create a list of available IPs from the VLAN CIDR not in use
  readarray -t unreserved_vlan_ips < <(nmap -sL -n --exclude "$ip_exclude_list" $cidr_block | awk '/Nmap scan report/{print $NF}')

  # return a random IP from the available IPs
  echo "${unreserved_vlan_ips[ $RANDOM % ${#unreserved_vlan_ips[@]} ]}/$cidr_network_identifier"

}

### main script ###

let counter=0

while true; do

# control loop will wait 60 seconds if not the first time through

if (( $counter > 0 ));
  then
    sleep 60s
  else
    let counter++
fi

# get the compute instance ID of the node we are running on

compute_instance_data=$( \
  curl -s "https://api.linode.com/v4/linode/instances" \
  -H "Authorization: Bearer $LINODE_API_TOKEN" \
  -H "X-Filter: { \"label\": \"$node_name\" }"
)

compute_instance_id=$( echo $compute_instance_data | jq '.data[0].id' )

if [ -z $compute_instance_id ];
  then
    echo "compute instance ID not found"
    continue
fi

# get nodes that currently belong to the VLAN and add to vlan_compute_instance_ids array

vlan_data=$( \
  curl -s "https://api.linode.com/v4beta/networking/vlans" \
  -H "Authorization: Bearer $LINODE_API_TOKEN" \
  -H "X-Filter: { \"label\": \"$vlan_name\" }"
)

if echo $vlan_data | grep "\"results\":\s*0" > /dev/null;
  then
    echo "VLAN doesn't yet exist"
  elif  echo $vlan_data | 
        jq -r --arg vlan_name "$vlan_name" \
        '.data[] | select(.label == $vlan_name) | .linodes[]' | \
        grep "$compute_instance_id" > /dev/null;
  then
    echo "Node currently exists in the VLAN $vlan_name"
    continue
  else
    readarray -t vlan_compute_instance_ids < <( echo $vlan_data | \
                                                jq -r --arg vlan_name "$vlan_name" \
                                                '.data[] | select(.label == $vlan_name) | .linodes[]' )
fi

# Build up the list of IP addresses in the VLAN

vlan_ip_list=()

for node in "${vlan_compute_instance_ids[@]}"
do
  # get current IPs in use in the VLAN and add them to our vlan_ip_list
  node_config=$( \
    curl -s "https://api.linode.com/v4/linode/instances/$node/configs/" \
    -H "Authorization: Bearer $LINODE_API_TOKEN"
  )

  node_vlan_ip=$( \
    echo $node_config | \
    jq -r --arg vlan_name "$vlan_name" \
    '.data[].interfaces[] | select( .label == $vlan_name ) | .ipam_address'
  )

  if [ $node_vlan_ip ];
  then
    echo "Adding IP: $node_vlan_ip to list of existing VLAN IPs in use"
    vlan_ip_list+=("$node_vlan_ip")
  fi
done

# select the IP we should use to register this node into the VLAN
ip_to_use=$(generate_ip "$vlan_cidr" "${vlan_ip_list[@]}")

echo "The IP chosen is: $ip_to_use"

### register the node to the VLAN ###

# get the configuration profiles for this instance
compute_instance_configs=$( \
  curl -s "https://api.linode.com/v4/linode/instances/$compute_instance_id/configs/" \
  -H "Authorization: Bearer $LINODE_API_TOKEN"
)

# under normal circumstances we should get one result
if echo $compute_instance_configs | grep "\"results\":\s*1" > /dev/null; 
  then
    this_config_id=$( echo $compute_instance_configs | jq -r '.data[0].id' )
elif echo $compute_instance_configs | grep "\"results\":\s*0" > /dev/null;
  then
    echo "Cannot retrieve config profile for this compute instance"
    continue
# in case the LKE instance has been customized and there are more than one config profiles
else
  this_config_id=$( echo $compute_instance_configs | jq -r '.data[] | select(.interfaces[].primary == true) | .id' )
fi

# add node to the VLAN

interfaces_json_data=$(cat <<EOF
{
    "interfaces": [{
            "purpose": "public",
            "primary": false,
            "active": true,
            "ipam_address": null,
            "label": null,
            "vpc_id": null,
            "subnet_id": null
        }, {
            "purpose": "vlan",
            "primary": false,
            "active": true,
            "ipam_address": "$ip_to_use",
            "label": "$vlan_name",
            "vpc_id": null,
            "subnet_id": null
        }
    ]
}
EOF
)

# Use configuration profile API to add and return the HTTP status code
add_vlan_interface_result=$( \
  curl -s -o /dev/null -w "%{http_code}" -X PUT "https://api.linode.com/v4/linode/instances/$compute_instance_id/configs/$this_config_id/" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Authorization: Bearer $LINODE_API_TOKEN" \
  --data @- <<EOF
  $interfaces_json_data
EOF
)

if [ $add_vlan_interface_result == 200 ];
  then
    echo "Node successfully added to VLAN"
  else
    echo "Unable to add node to VLAN"
    continue
fi

# reboot the node for interface updates to take effect

node_reboot_result=$( \
  curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.linode.com/v4/linode/instances/$compute_instance_id/reboot/" \
  -H "Authorization: Bearer $LINODE_API_TOKEN"
)
  
if [ $node_reboot_result == 200 ];
  then
    echo "Node is rebooting"
  else
    echo "Unable to reboot node"
    continue
fi

done;