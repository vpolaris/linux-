FROM scratch
LABEL maintainer="szfd9g <szfd9g@live.fr>"                    
ENV DISTTAG=f33container FGC=f33 FBR=f33 container=podman
ENV DNFOPTION="--setopt=install_weak_deps=False --nodocs"
ARG admpass
ARG OS
ARG HTTPS
#Add Fedora image Container from Fedora-Container-Base-33-1.2.x86_64.tar.xz
ADD layer.tar / 

#System update
RUN dnf makecache; \
dnf -y upgrade dnf rpm yum libmodulemd $DNFOPTION; \
dnf -y upgrade $DNFOPTION

#Install apache

RUN dnf -y install httpd mod_ssl openssl $DNFOPTION

#Install Dev tools
RUN dnf -y install git gcc openssl-devel python2 $DNFOPTION
RUN echo "Selected OS is ${OS}";if [ "${OS}" == "CentOS" ]; then dnf -y install gcc-c++ make $DNFOPTION; \
else dnf -y install g++ $DNFOPTION; fi

#Install Rust
RUN curl  -Lo /tmp/sh.rustup.rs -sSf https://sh.rustup.rs; \
bash -E /tmp/sh.rustup.rs -y --default-host "$(uname -m)"-unknown-linux-gnu --default-toolchain nightly --profile minimal
ENV PATH="~/.cargo/bin:${PATH}"

#Install Node.JS and npm
RUN curl -Lo /tmp/setup_14.x -sSf https://rpm.nodesource.com/setup_14.x; \
bash -E /tmp/setup_14.x; \
dnf -y install nodejs $DNFOPTION

#Compile the back-end
RUN git clone https://github.com/dani-garcia/vaultwarden.git /tmp/bitwarden; \
~/.cargo/bin/cargo build --features sqlite --release --manifest-path=/tmp/bitwarden/Cargo.toml

#Compile the front-end

RUN git clone https://github.com/bitwarden/web.git /tmp/vault; \
cd /tmp/vault; \
tag="$(git tag -l "v2.19*" | tail -n1)"; export tag; echo "Selected tag version is ${tag}"; \
git checkout ${tag}
RUN cd /tmp/vault; git submodule update --recursive --init
RUN curl -Lo /tmp/vault/v2.19.0.patch -sSf https://raw.githubusercontent.com/dani-garcia/bw_web_builds/master/patches/v2.19.0.patch; \
git -C /tmp/vault apply /tmp/vault/v2.19.0.patch
RUN npm run sub:init --prefix /tmp/vault;npm install --prefix /tmp/vault
RUN npm audit fix --prefix /tmp/vault;npm run dist --prefix /tmp/vault


#Create bitwarden user and admin container manager
RUN adduser -u 10500 --shell /bin/false --comment "Bitwarden RS User Service" --user-group -M bitwarden

RUN if [[ -z "$admpass" ]] ; then \
user_password="$(tr -cd [:alnum:] < /dev/urandom | fold -w 16 | head -n 1)";export user_password; adduser --shell /bin/bash --comment "Admin RS server" --user-group -G wheel -m --password $(mkpasswd -H md5 ${user_password}) admin;echo "Admin RS Password is ${user_password}"; \
else adduser --shell /bin/bash --comment "Admin RS server" --user-group -G wheel -m --password $(openssl passwd -1 ${admpass}) admin;echo "Admin RS Password is ${admpass}";fi


#Create Directory Structure
RUN if ! [ -d  "var/lib/bitwarden/data" ]; then	mkdir -p /var/lib/bitwarden/{data,certs,logs/{bitwarden,httpd}};fi
RUN mkdir -p /etc/bitwarden /home/admin/.ssl; \
chown -R bitwarden:bitwarden /var/lib/bitwarden/; \
chown -R admin:bitwarden /home/admin/.ssl

#Move files and set permissions

#Bitwarden RS server
RUN mv /tmp/bitwarden/target/release/vaultwarden /usr/local/bin/bitwarden
COPY ./configurations/.env /etc/bitwarden/.env
RUN chmod -R 750 /usr/local/bin/bitwarden /var/lib/bitwarden/; \
chmod -R 770 /etc/bitwarden/; \
chown -R root:bitwarden /usr/local/bin/bitwarden /etc/bitwarden/

#Apache
COPY ./configurations/ssl.conf /etc/httpd/conf.d/ssl.conf
COPY ./configurations/serveur-status.conf /etc/httpd/conf.d/serveur-status.conf
COPY ./configurations/vhost.conf /etc/httpd/conf.d/vhost.conf
RUN chmod 644 /etc/httpd/conf.d/{ssl.conf,vhost.conf,serveur-status.conf}
RUN cp -a /tmp/vault/build/ /var/www/vault/; \
chown -R apache:apache /var/www/vault/ /var/lib/bitwarden/logs/httpd

#Create certificates and keys for Vault if are not provided
RUN if ! [ -f  "/var/lib/bitwarden/certs/CA-Bitwarden.pem" ]; then \
openssl req -new -x509 -nodes -days 7300 -outform PEM -newkey rsa:4096 -sha256 \
-keyout /home/admin/.ssl/CA-Bitwarden.key \
-out /home/admin/.ssl/CA-Bitwarden.pem \
-subj "/CN=CA Bitwarden/emailAddress=admin@${DOMAIN}/C=FR/ST=IDF/L=Paris/O=Podman Inc/OU=Podman builder"; \
cp /home/admin/.ssl/CA-Bitwarden.* /var/lib/bitwarden/certs; \
else cp /var/lib/bitwarden/certs/CA-Bitwarden.pem /home/admin/.ssl/CA-Bitwarden.pem; fi

RUN if [ -f  "/var/lib/bitwarden/certs/CA-Bitwarden.key" ]; then \
cp /var/lib/bitwarden/certs/CA-Bitwarden.key /home/admin/.ssl/CA-Bitwarden.key;fi

RUN if ! [ -f  "/var/lib/bitwarden/certs/bitwarden.pem" ]; then \
openssl req -nodes -newkey rsa:2048 -sha256 \
-keyout /etc/pki/tls/private/bitwarden.key \
-out /home/admin/.ssl/bitwarden.csr \
-subj "/CN=${DOMAIN}/emailAddress=admin@${DOMAIN}/C=FR/ST=IDF/L=Paris/O=Podman Inc/OU=Podman builder"; \
cp /home/admin/.ssl/bitwarden.csr /var/lib/bitwarden/certs; \
cp /etc/pki/tls/private/bitwarden.key /var/lib/bitwarden/certs; \
else cp /var/lib/bitwarden/certs/bitwarden.csr /home/admin/.ssl/bitwarden.csr; \
cp /var/lib/bitwarden/certs/bitwarden.key /etc/pki/tls/private/bitwarden.key; fi

RUN if ! [ -f  "/var/lib/bitwarden/certs/bitwarden.pem" ]; then \
openssl x509 -req -outform PEM -CAcreateserial \
-in /home/admin/.ssl/bitwarden.csr \
-CA /home/admin/.ssl/CA-Bitwarden.pem \
-CAkey /home/admin/.ssl/CA-Bitwarden.key \
-out /etc/pki/tls/certs/bitwarden.pem; \
cp /etc/pki/tls/certs/bitwarden.pem /var/lib/bitwarden/certs; \
else cp /var/lib/bitwarden/certs/bitwarden.pem /etc/pki/tls/certs/bitwarden.pem; fi

#Set file permissions and add CA to SSL store
RUN chmod 440 /etc/pki/tls/private/bitwarden.key; \
chmod 644 /etc/pki/tls/certs/bitwarden.pem ; \
chmod 644 /home/admin/.ssl/CA-Bitwarden.pem; \
cp /home/admin/.ssl/CA-Bitwarden.pem /etc/pki/ca-trust/source/anchors/; \
update-ca-trust

RUN if [ -f  "/home/admin/.ssl/CA-Bitwarden.key" ]; then \
chmod 440 /home/admin/.ssl/CA-Bitwarden.key;fi


#Systemd configuration
RUN mkdir /etc/systemd/system/{httpd.service.d,system.slice.d}
COPY ./services/bitwarden.service /etc/systemd/system/bitwarden.service
COPY ./services/bitwarden-httpd.slice /etc/systemd/system/bitwarden-httpd.slice
COPY ./services/healthcheck.timer /etc/systemd/system/healthcheck.timer
COPY ./services/slice.conf /etc/systemd/system/httpd.service.d/slice.conf
COPY ./services/memorymax.conf /etc/systemd/system/system.slice.d/memorymax.conf
RUN chmod 644 /etc/systemd/system/{bitwarden.service,healthcheck.timer,bitwarden-httpd.slice} /etc/systemd/system/httpd.service.d/slice.conf
RUN systemctl enable bitwarden.service httpd.service
CMD ["/usr/sbin/init"]


#Used only if Dockerfile is not set by setup
RUN if [ -z ${HTTPS} ]; then export HTTPS="443";fi
EXPOSE ${HTTPS}

#Clean up
RUN if [ "${OS}" == "CentOS" ]; then dnf -y remove gcc-c++ make xz tar squashfs-tools snappy --setopt=clean_requirements_on_remove=1; \
else dnf -y remove g++ --setopt=clean_requirements_on_remove=1; fi

RUN rm -f /tmp/sh.rustup.rs /tmp/setup_14.x; \
rm -rf /tmp/bitwarden/ /tmp/vault; \
yes | ~/.cargo/bin/rustup self uninstall; \
rm -rf ~/.config/ ~/.node-gyp/ ~/.npm ~/anaconda-* ~/original-ks.cfg; \
dnf -y remove nodejs git gcc openssl-devel python2 --setopt=clean_requirements_on_remove=1; \
dnf -y autoremove; \
dnf clean all

RUN touch /var/lib/bitwarden/build.completed

