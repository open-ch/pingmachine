FROM perl:5.34

COPY . /app
WORKDIR /app

RUN apt-get update && apt-get install -y pkg-config gettext xml2 libpango1.0-dev libcairo2-dev groff-base fping httping

RUN cpanm --installdeps .

VOLUME /var/lib/pingmachine

ENTRYPOINT [ "perl", "-I./lib", "./pingmachine" ]
CMD [ "--debug" ]
