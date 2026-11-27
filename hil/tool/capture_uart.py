from datetime import datetime, timezone
import sys
import serial

with serial.Serial(sys.argv[1], 115200, timeout=1, exclusive=True) as uart:
    while True:
        line = uart.readline()
        if line:
            print(datetime.now(timezone.utc).isoformat(), line.decode(errors="replace").rstrip())
