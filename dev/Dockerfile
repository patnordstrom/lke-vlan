FROM bash:latest

USER root

RUN apk -q add jq curl nmap

RUN mkdir /lke-vlan

WORKDIR /lke-vlan

CMD [ "tail", "-f", "/dev/null" ]