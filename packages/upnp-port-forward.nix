{
  writeScriptBin,
  python3,
}:
# UPnP port-forward helper.
#
# Commands:
#   upnp-port-forward add <device-port> <wan-port> [--protocol tcp|udp]
#   upnp-port-forward list
#   upnp-port-forward delete <wan-port> [--protocol tcp|udp]
#   upnp-port-forward delete-all [--all]
#   upnp-port-forward ensure-moonlight
#
# `delete-all` only removes mappings tagged with "upnp-port-forward" by
# default; pass `--all` to remove every mapping on the router.
writeScriptBin "upnp-port-forward" ''
  #!${python3}/bin/python3
  """CLI to manage UPnP port mappings on the local router.

  Commands:
    add <device-port> <wan-port>   Add a port mapping (device port -> WAN port)
    list                           List all port mappings on the router
    delete <wan-port>              Delete one mapping (default protocol TCP)
    delete-all                     Delete mappings created by this tool (or all with --all)
    ensure-moonlight               Ensure the standard Moonlight/Sunshine ports are mapped
  """

  import argparse
  import os
  import socket
  import sys
  import time
  import urllib.error
  import urllib.parse
  import urllib.request
  import xml.etree.ElementTree as ET

  DEFAULT_LOCAL_IP = os.environ.get("UPNP_LOCAL_IP", "192.168.1.100")
  DESCRIPTION_PREFIX = "upnp-port-forward"
  MOONLIGHT_DESCRIPTION = "Moonlight (upnp-port-forward)"
  MOONLIGHT_PORTS = {
      "TCP": [47984, 47989, 48010],
      "UDP": [47998, 47999, 48000, 48002, 48010],
  }

  IGD_DEVICE_TYPE = "urn:schemas-upnp-org:device:InternetGatewayDevice:1"
  WANIP_SERVICE_TYPE = "urn:schemas-upnp-org:service:WANIPConnection:1"
  SSDP_ADDR = ("239.255.255.250", 1900)
  SSDP_MSG = (
      "M-SEARCH * HTTP/1.1\r\n"
      "HOST: 239.255.255.250:1900\r\n"
      'MAN: "ssdp:discover"\r\n'
      "MX: 3\r\n"
      f"ST: {IGD_DEVICE_TYPE}\r\n"
      "\r\n"
  ).encode()


  def local_name(tag):
      return tag.split("}")[-1]


  def discover_locations(timeout=5.0):
      locations = []
      sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
      sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      try:
          sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
      except OSError:
          pass
      sock.settimeout(0.5)
      try:
          sock.bind(("", 0))
      except OSError as exc:
          print(f"warning: bind failed: {exc}", file=sys.stderr)
      sock.sendto(SSDP_MSG, SSDP_ADDR)
      start = time.monotonic()
      try:
          while time.monotonic() - start < timeout:
              try:
                  data, _ = sock.recvfrom(65535)
              except socket.timeout:
                  continue
              text = data.decode("utf-8", "replace")
              for line in text.splitlines():
                  if line.lower().startswith("location:"):
                      loc = line.split(":", 1)[1].strip()
                      if loc not in locations:
                          locations.append(loc)
      finally:
          sock.close()
      return locations


  def fetch_xml(url, timeout=8.0):
      req = urllib.request.Request(url, headers={"User-Agent": "upnp-port-forward/1.0"})
      with urllib.request.urlopen(req, timeout=timeout) as resp:
          return ET.fromstring(resp.read())


  def find_wanip_control_url(location):
      try:
          root = fetch_xml(location)
      except Exception as exc:
          print(f"warning: could not fetch {location}: {exc}", file=sys.stderr)
          return None

      def walk(elem):
          for child in elem:
              name = local_name(child.tag)
              if name == "serviceList":
                  for svc in child:
                      svc_type = None
                      ctrl = None
                      for field in svc:
                          fname = local_name(field.tag)
                          if fname == "serviceType":
                              svc_type = (field.text or "").strip()
                          elif fname == "controlURL":
                              ctrl = (field.text or "").strip()
                      if svc_type == WANIP_SERVICE_TYPE and ctrl:
                          return ctrl
              found = walk(child)
              if found:
                  return found
          return None

      ctrl = walk(root)
      if not ctrl:
          return None
      return urllib.parse.urljoin(location, ctrl)


  def discover_control_url():
      locations = discover_locations()
      if not locations:
          print("error: no UPnP InternetGatewayDevice found via SSDP", file=sys.stderr)
          sys.exit(1)
      for location in locations:
          ctrl = find_wanip_control_url(location)
          if ctrl:
              return ctrl
      print("error: no WANIPConnection service found in discovered devices", file=sys.stderr)
      sys.exit(1)


  def soap_call(ctrl_url, action, args, timeout=8.0):
      body = (
          '<?xml version="1.0"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
          f"<s:Body><u:{action} xmlns:u=\"{WANIP_SERVICE_TYPE}\">"
      )
      for key, value in args.items():
          body += f"<{key}>{value}</{key}>"
      body += f"</u:{action}></s:Body></s:Envelope>"

      req = urllib.request.Request(ctrl_url, data=body.encode("utf-8"), method="POST")
      req.add_header("Content-Type", 'text/xml; charset="utf-8"')
      req.add_header("SOAPAction", f'"{WANIP_SERVICE_TYPE}#{action}"')
      try:
          with urllib.request.urlopen(req, timeout=timeout) as resp:
              return resp.status, resp.read().decode("utf-8", "replace")
      except urllib.error.HTTPError as exc:
          return exc.code, exc.read().decode("utf-8", "replace")


  def parse_response(data, action):
      try:
          root = ET.fromstring(data)
      except ET.ParseError:
          return {}
      for elem in root.iter():
          if local_name(elem.tag) == f"{action}Response":
              return {local_name(child.tag): (child.text or "").strip() for child in elem}
      return {}


  def get_mapping(ctrl_url, external_port, protocol):
      status, data = soap_call(
          ctrl_url,
          "GetSpecificPortMappingEntry",
          {
              "NewRemoteHost": "",
              "NewExternalPort": str(external_port),
              "NewProtocol": protocol,
          },
      )
      if status == 200:
          return parse_response(data, "GetSpecificPortMappingEntry")
      return None


  def add_mapping(ctrl_url, internal_port, external_port, protocol, local_ip, description, lease):
      status, data = soap_call(
          ctrl_url,
          "AddPortMapping",
          {
              "NewRemoteHost": "",
              "NewExternalPort": str(external_port),
              "NewProtocol": protocol,
              "NewInternalPort": str(internal_port),
              "NewInternalClient": local_ip,
              "NewEnabled": "1",
              "NewPortMappingDescription": description,
              "NewLeaseDuration": str(lease),
          },
      )
      if status == 200:
          return True
      code = ""
      try:
          root = ET.fromstring(data)
          for elem in root.iter():
              if local_name(elem.tag) == "errorCode":
                  code = (elem.text or "").strip()
                  break
      except ET.ParseError:
          pass
      print(f"error: AddPortMapping failed (HTTP {status}) errorCode={code or '?'}", file=sys.stderr)
      if data:
          print(data[:500], file=sys.stderr)
      return False


  def delete_mapping(ctrl_url, external_port, protocol):
      status, data = soap_call(
          ctrl_url,
          "DeletePortMapping",
          {
              "NewRemoteHost": "",
              "NewExternalPort": str(external_port),
              "NewProtocol": protocol,
          },
      )
      if status == 200:
          return True
      code = ""
      try:
          root = ET.fromstring(data)
          for elem in root.iter():
              if local_name(elem.tag) == "errorCode":
                  code = (elem.text or "").strip()
                  break
      except ET.ParseError:
          pass
      print(f"error: DeletePortMapping failed (HTTP {status}) errorCode={code or '?'}", file=sys.stderr)
      if data:
          print(data[:500], file=sys.stderr)
      return False


  def list_mappings(ctrl_url):
      mappings = []
      for i in range(65535):
          status, data = soap_call(
              ctrl_url,
              "GetGenericPortMappingEntry",
              {"NewPortMappingIndex": str(i)},
          )
          if status != 200:
              break
          m = parse_response(data, "GetGenericPortMappingEntry")
          if not m.get("NewExternalPort"):
              break
          mappings.append(m)
      return mappings


  def normalize_protocol(proto):
      proto = (proto or "tcp").upper()
      if proto not in ("TCP", "UDP"):
          print(f"error: protocol must be tcp or udp, got {proto}", file=sys.stderr)
          sys.exit(2)
      return proto


  def cmd_add(args):
      ctrl = discover_control_url()
      proto = normalize_protocol(args.protocol)
      description = args.description or DESCRIPTION_PREFIX
      if args.internal_port < 1 or args.internal_port > 65535 or args.wan_port < 1 or args.wan_port > 65535:
          print("error: ports must be 1-65535", file=sys.stderr)
          sys.exit(2)
      if add_mapping(ctrl, args.internal_port, args.wan_port, proto, args.ip, description, args.lease):
          print(f"added {proto} {args.wan_port} -> {args.ip}:{args.internal_port} ({description})")
      else:
          sys.exit(1)


  def cmd_list(args):
      ctrl = discover_control_url()
      mappings = list_mappings(ctrl)
      if not mappings:
          print("no UPnP port mappings found")
          return
      print(f"{'#':<4} {'Protocol':<8} {'ExternalPort':<12} {'InternalClient':<16} {'InternalPort':<12} {'Enabled':<8} {'Lease':<10} Description")
      for i, m in enumerate(mappings):
          print(f"{i:<4} {m.get('NewProtocol', '''):<8} {m.get('NewExternalPort', '''):<12} "
                f"{m.get('NewInternalClient', '''):<16} {m.get('NewInternalPort', '''):<12} "
                f"{m.get('NewEnabled', '''):<8} {m.get('NewLeaseDuration', '''):<10} {m.get('NewPortMappingDescription', ''')}")


  def cmd_delete(args):
      ctrl = discover_control_url()
      proto = normalize_protocol(args.protocol)
      existing = get_mapping(ctrl, args.wan_port, proto)
      if not existing:
          print(f"no existing {proto} mapping on WAN port {args.wan_port}")
          return
      if delete_mapping(ctrl, args.wan_port, proto):
          print(f"deleted {proto} {args.wan_port} -> {existing.get('NewInternalClient', '?')}:{existing.get('NewInternalPort', '?')}")
      else:
          sys.exit(1)


  def cmd_delete_all(args):
      ctrl = discover_control_url()
      mappings = list_mappings(ctrl)
      to_delete = mappings if args.all else [m for m in mappings if m.get("NewPortMappingDescription", "").startswith(DESCRIPTION_PREFIX)]
      if not to_delete:
          print("nothing to delete")
          return
      print(f"deleting {len(to_delete)} mapping(s)...")
      failed = False
      for m in to_delete:
          proto = m.get("NewProtocol", "TCP")
          port = m.get("NewExternalPort")
          if not port:
              continue
          if delete_mapping(ctrl, port, proto):
              print(f"deleted {proto} {port} -> {m.get('NewInternalClient', '?')}:{m.get('NewInternalPort', '?')} ({m.get('NewPortMappingDescription', ''')})")
          else:
              failed = True
      if failed:
          sys.exit(1)


  def cmd_ensure_moonlight(args):
      ctrl = discover_control_url()
      failed = False
      for proto, ports in MOONLIGHT_PORTS.items():
          for port in ports:
              existing = get_mapping(ctrl, port, proto)
              if existing is not None and existing.get("NewInternalClient") == args.ip:
                  print(f"ok {proto} {port} -> {args.ip} (already mapped)")
                  continue
              if existing is not None:
                  print(f"conflict {proto} {port}: already mapped to {existing.get('NewInternalClient', '?')}, not modifying", file=sys.stderr)
                  failed = True
                  continue
              if add_mapping(ctrl, port, port, proto, args.ip, MOONLIGHT_DESCRIPTION, args.lease):
                  print(f"added {proto} {port} -> {args.ip}")
              else:
                  failed = True
      if failed:
          sys.exit(1)


  def build_parser():
      parser = argparse.ArgumentParser(prog="upnp-port-forward", description="Manage UPnP port mappings on the local router")
      parser.add_argument("--ip", default=DEFAULT_LOCAL_IP, help=f"Local LAN IP to forward to (default: {DEFAULT_LOCAL_IP})")
      parser.add_argument("--lease", type=int, default=0, help="Lease duration in seconds, 0 = permanent (default: 0)")
      sub = parser.add_subparsers(dest="command", required=True)

      add = sub.add_parser("add", help="Add a port mapping")
      add.add_argument("internal_port", type=int, help="Device/internal port")
      add.add_argument("wan_port", type=int, help="Router/WAN port to expose")
      add.add_argument("--protocol", default="tcp", help="tcp or udp (default: tcp)")
      add.add_argument("--description", default=None, help="Description/tag (default: upnp-port-forward)")
      add.set_defaults(func=cmd_add)

      lst = sub.add_parser("list", help="List all port mappings")
      lst.set_defaults(func=cmd_list)

      delete = sub.add_parser("delete", help="Delete one port mapping")
      delete.add_argument("wan_port", type=int, help="Router/WAN port to delete")
      delete.add_argument("--protocol", default="tcp", help="tcp or udp (default: tcp)")
      delete.set_defaults(func=cmd_delete)

      delete_all = sub.add_parser("delete-all", help="Delete mappings created by this tool (or all with --all)")
      delete_all.add_argument("--all", action="store_true", help="Delete EVERY mapping on the router (dangerous)")
      delete_all.set_defaults(func=cmd_delete_all)

      ensure = sub.add_parser("ensure-moonlight", help="Ensure standard Moonlight/Sunshine ports are mapped")
      ensure.set_defaults(func=cmd_ensure_moonlight)

      return parser


  def main():
      args = build_parser().parse_args()
      args.func(args)


  if __name__ == "__main__":
      main()
''
