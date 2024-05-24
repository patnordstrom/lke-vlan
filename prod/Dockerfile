FROM bash:latest

USER root

RUN apk -q add jq curl nmap
RUN mkdir /lke-vlan
COPY main.sh /lke-vlan
RUN chmod +x /lke-vlan/main.sh

ENTRYPOINT [ "/lke-vlan/main.sh" ] 