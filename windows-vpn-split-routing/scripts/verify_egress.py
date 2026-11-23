"""Verify Windows interface binding and local proxy egress without printing public IPs."""
import argparse
import http.client
import ipaddress
import json
import socket
import struct
import sys


def connection_for_interface(index):
    def connect(address, timeout=12, source_address=None, **kwargs):
        error = None
        for family, kind, protocol, _, target in socket.getaddrinfo(address[0], address[1], socket.AF_INET, socket.SOCK_STREAM):
            sock = socket.socket(family, kind, protocol)
            try:
                sock.settimeout(timeout)
                # Windows IP_UNICAST_IF expects a network-byte-order interface index.
                sock.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', index))
                if source_address:
                    sock.bind(source_address)
                sock.connect(target)
                return sock
            except OSError as exc:
                error = exc
                sock.close()
        raise error or OSError('No IPv4 route')
    return connect


def public_address(interface_index=None, proxy_port=None):
    if proxy_port:
        conn = http.client.HTTPSConnection('127.0.0.1', proxy_port, timeout=12)
        conn.set_tunnel('api.ipify.org', 443)
    else:
        conn = http.client.HTTPSConnection('api.ipify.org', timeout=12)
        conn._create_connection = connection_for_interface(interface_index)
    try:
        conn.request('GET', '/?format=json', headers={'User-Agent': 'split-route-diagnostic/1.0'})
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(f'IP echo returned HTTP {response.status}')
        address = json.loads(response.read(4096))['ip']
        return str(ipaddress.ip_address(address))
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--direct-index', type=int, required=True)
    parser.add_argument('--vpn-index', type=int, required=True)
    parser.add_argument('--proxy-port', type=int, required=True)
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('This diagnostic uses Windows IP_UNICAST_IF')
    if args.direct_index <= 0 or args.vpn_index <= 0 or args.direct_index == args.vpn_index or not 1024 <= args.proxy_port <= 65535:
        parser.error('Expected different positive interface indices and a valid local port')
    try:
        direct = public_address(interface_index=args.direct_index)
        vpn = public_address(interface_index=args.vpn_index)
        proxy = public_address(proxy_port=args.proxy_port)
    except (OSError, ValueError, RuntimeError, http.client.HTTPException) as exc:
        print(json.dumps({'verified': False, 'error_class': type(exc).__name__}))
        return 1
    result = {'direct_and_vpn_differ': direct != vpn, 'proxy_foreign_matches_vpn': proxy == vpn}
    result['verified'] = all(result.values())
    print(json.dumps(result))
    return 0 if result['verified'] else 1


if __name__ == '__main__':
    sys.exit(main())
