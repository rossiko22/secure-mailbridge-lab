#!/usr/bin/env python3
"""Generate synthetic test captures for suricata-rules/rules/local.rules.

Uses only the standard library, so anyone can repeat it. Run from this
directory. Checksums are left at zero, so test with: suricata -k none

The traffic is fake and uses example.test, never the real domain.
"""
import struct

CLIENT = bytes([10, 8, 0, 2])
PROXY = bytes([10, 0, 2, 10])
SYN, ACK, PSH, FIN = 0x02, 0x10, 0x08, 0x01


def tcp_packet(src, dst, sport, dport, seq, ack, flags, payload=b""):
    tcp = struct.pack("!HHIIBBHHH", sport, dport, seq, ack, 5 << 4, flags, 65535, 0, 0)
    total = 20 + len(tcp) + len(payload)
    ip = struct.pack("!BBHHHBBH", 0x45, 0, total, 1, 0x4000, 63, 6, 0) + src + dst
    ether = b"\x02\x00\x00\x00\x00\x01\x02\x00\x00\x00\x00\x02\x08\x00"
    return ether + ip + tcp + payload


def write_pcap(path, packets):
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for i, packet in enumerate(packets):
            f.write(struct.pack("<IIII", 1700000000, i * 1000, len(packet), len(packet)))
            f.write(packet)


def session(client_data, server_data, sport=40000):
    """A complete TCP session: handshake, one exchange, close."""
    c, s = 1000, 5000
    out = [
        tcp_packet(CLIENT, PROXY, sport, 443, c, 0, SYN),
        tcp_packet(PROXY, CLIENT, 443, sport, s, c + 1, SYN | ACK),
        tcp_packet(CLIENT, PROXY, sport, 443, c + 1, s + 1, ACK),
    ]
    c += 1
    s += 1
    out.append(tcp_packet(CLIENT, PROXY, sport, 443, c, s, PSH | ACK, client_data))
    c += len(client_data)
    out.append(tcp_packet(PROXY, CLIENT, 443, sport, s, c, PSH | ACK, server_data))
    s += len(server_data)
    out.append(tcp_packet(CLIENT, PROXY, sport, 443, c, s, ACK))
    out.append(tcp_packet(CLIENT, PROXY, sport, 443, c, s, FIN | ACK))
    out.append(tcp_packet(PROXY, CLIENT, 443, sport, s, c + 1, FIN | ACK))
    out.append(tcp_packet(CLIENT, PROXY, sport, 443, c + 1, s + 1, ACK))
    return out


def client_hello(version, sni):
    name = sni.encode()
    server_name = struct.pack("!HBH", len(name) + 3, 0, len(name)) + name
    extension = struct.pack("!HH", 0, len(server_name)) + server_name
    extensions = struct.pack("!H", len(extension)) + extension
    body = (
        struct.pack("!H", version)
        + bytes(32)  # random
        + b"\x00"  # session id length
        + struct.pack("!HH", 2, 0x002F)  # one cipher suite
        + b"\x01\x00"  # one compression method
        + extensions
    )
    handshake = b"\x01" + struct.pack("!I", len(body))[1:] + body
    return b"\x16" + struct.pack("!HH", version, len(handshake)) + handshake


def server_hello(version):
    body = struct.pack("!H", version) + bytes(32) + b"\x00" + struct.pack("!H", 0x002F) + b"\x00"
    handshake = b"\x02" + struct.pack("!I", len(body))[1:] + body
    return b"\x16" + struct.pack("!HH", version, len(handshake)) + handshake


TLS10, TLS12 = 0x0301, 0x0303

write_pcap("non-tls.pcap", session(b"tunnel data, not TLS\n" * 10, b"plain reply\n" * 10))
write_pcap("http.pcap", session(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n", b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
write_pcap("tls10.pcap", session(client_hello(TLS10, "mail.example.test"), server_hello(TLS10)))
write_pcap("bad-sni.pcap", session(client_hello(TLS12, "other.example.test"), server_hello(TLS12)))
write_pcap("clean-tls.pcap", session(client_hello(TLS12, "mail.example.test"), server_hello(TLS12)))
write_pcap(
    "flood.pcap",
    [tcp_packet(CLIENT, PROXY, 41000 + i, 443, 1000, 0, SYN) for i in range(70)],
)
