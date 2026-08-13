{
  config,
  lib,
  pkgs,
  ...
}: let
  # FastAPI-DLS 1.x — clean-room minimal DLS; v1.x supports vGPU 16.x/17.x.
  # Mirrored on GitHub (upstream gitlab is private); source tag 1.5.4.
  fastapiDlsSrc = pkgs.fetchFromGitHub {
    owner = "GreenDamTan";
    repo = "fastapi-dls_mirror";
    rev = "1.5.4";
    sha256 = "1hpk90ga8rwqmh2h7hhw9jaxcddph8x8m7s3p39w2ndiqi9rnlx6";
  };

  fastapiDlsApp = pkgs.stdenv.mkDerivation {
    pname = "fastapi-dls";
    version = "1.5.4";
    src = fastapiDlsSrc;
    installPhase = ''
      mkdir -p $out/lib/fastapi-dls
      cp -r app/* $out/lib/fastapi-dls/
    '';
  };

  fastapiDlsEnv = pkgs.python3.withPackages (ps: [
    ps.fastapi
    ps.uvicorn
    ps.python-jose
    ps.cryptography
    ps.python-dateutil
    ps.sqlalchemy
    ps.markdown
    ps.python-dotenv
  ]);

  dlsUrl = "192.168.3.151";
  stateDir = "/var/lib/fastapi-dls";
in {
  systemd.services.fastapi-dls = {
    description = "FastAPI-DLS NVIDIA vGPU license server";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];

    preStart = ''
      CERT_DIR=${stateDir}/cert
      mkdir -p "$CERT_DIR"
      if [ ! -f "$CERT_DIR/instance.private.pem" ]; then
        ${pkgs.openssl}/bin/openssl genrsa -out "$CERT_DIR/instance.private.pem" 2048
        ${pkgs.openssl}/bin/openssl rsa -in "$CERT_DIR/instance.private.pem" -outform PEM -pubout -out "$CERT_DIR/instance.public.pem"
      fi
      if [ ! -f "$CERT_DIR/webserver.key" ]; then
        ${pkgs.openssl}/bin/openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
          -keyout "$CERT_DIR/webserver.key" -out "$CERT_DIR/webserver.crt" \
          -subj "/CN=${dlsUrl}" -addext "subjectAltName=IP:${dlsUrl}"
      fi
    '';

    serviceConfig = {
      Type = "simple";
      ExecStart = "${fastapiDlsEnv}/bin/uvicorn main:app --host 0.0.0.0 --port 443 --ssl-keyfile ${stateDir}/cert/webserver.key --ssl-certfile ${stateDir}/cert/webserver.crt";
      WorkingDirectory = "${fastapiDlsApp}/lib/fastapi-dls";
      Environment = [
        "PYTHONPATH=${fastapiDlsApp}/lib/fastapi-dls"
        "DLS_URL=${dlsUrl}"
        "DLS_PORT=443"
        "LEASE_EXPIRE_DAYS=90"
        "DATABASE=sqlite:///${stateDir}/db.sqlite"
        "DEBUG=false"
        "INSTANCE_KEY_RSA=${stateDir}/cert/instance.private.pem"
        "INSTANCE_KEY_PUB=${stateDir}/cert/instance.public.pem"
      ];
      Restart = "on-failure";
      RestartSec = "3s";
      DynamicUser = true;
      StateDirectory = "fastapi-dls";
    };
  };
}
