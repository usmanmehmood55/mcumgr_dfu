"""Pass raw Dart SMP frames through the WellSole OTA peer's serial fixture."""
import json
import re
import sys
from pathlib import Path

root, port, side, dut_id, peer_id = sys.argv[1:]
sys.path.insert(0, str(Path(root) / "tests" / "hil" / "runners"))
from run_ota import SerialPeer
from serial import Serial

with Serial(port, 115200, timeout=0.1, exclusive=True) as uart:
    peer = SerialPeer(uart, side, bytes.fromhex(dut_id), bytes.fromhex(peer_id))
    for line in sys.stdin:
        try:
            request = json.loads(line)
            command = request["command"]
            if command == "connect":
                peer.connect()
                result = {"connected": True}
            elif command == "disconnect":
                peer.disconnect()
                result = {"connected": False}
            elif command == "write":
                frame = bytes.fromhex(request["frame"])
                reset = frame[:1] == b"\x02" and frame[4:6] == b"\x00\x00" and frame[7] == 5
                if reset:
                    peer.arm_reset()
                try:
                    transcript = peer.operation("ota exchange " + frame.hex(), 45)
                except RuntimeError:
                    if not reset:
                        raise
                    transcript = ""
                response = re.search(r"OTA_RESPONSE ([0-9a-fA-F]+)", transcript)
                if reset:
                    peer.wait_reset()
                    peer.disconnect()
                if not response and not reset:
                    raise RuntimeError("Peer returned no SMP response")
                result = {"frame": response[1] if response else None, "connected": not reset}
            else:
                raise ValueError(f"Unknown command {command}")
            print(json.dumps(result), flush=True)
        except Exception as error:
            print(json.dumps({"error": str(error)}), flush=True)
