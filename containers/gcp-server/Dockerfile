# Dockerfile for the main Dark app

FROM dark-ocaml-service:latest

COPY --chown=dark . ./

RUN ./scripts/support/check-linked-libs bin/server.exe
RUN ./scripts/support/check-linked-libs bin/emergency_login_script.exe

CMD "./gcp-run-server"