"""Start Glances with a CPU temperature source on Windows.

Glances reads the CPU temperature only through psutil.sensors_temperatures(),
and psutil has no such function on Windows. This launcher adds it, then starts
Glances. The value comes from the sensor "Core (Tctl/Tdie)" of
LibreHardwareMonitorLib (loaded with pythonnet). Glances sees it as a sensor
with the label "Tctl", and the Homepage widget "glances" reads that label.

Use it in place of "python.exe -m glances". Every argument goes to Glances:

    python.exe glances_lhm.py -w -B 198.51.100.10

If the library does not load, Glances still runs and shows no temperature.
Read README.md in this directory.
"""
import atexit
import collections
import logging
import os
import threading
import time

import psutil

# The service runs as LocalSystem. It loads this library, so the directory
# must be writable by SYSTEM and Administrators only. Set-GlancesLauncher.ps1
# copies the library to "lib" next to this file, in C:\Program Files\GlancesLhm.
# GLANCES_LHM_DIR is for tests. Never point it at a directory that a normal
# user can write.
LIB_DIR = os.environ.get(
    "GLANCES_LHM_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"),
)
SENSOR_PREFIX = "Core (Tctl"  # The name of the sensor in LibreHardwareMonitor.
GLANCES_LABEL = "Tctl"  # The label that the Homepage widget looks for.
CACHE_SECONDS = 4  # Glances asks often. One read of the hardware is enough.
RETRY_SECONDS = 60  # Wait this time after a failure before the next try.

Temperature = collections.namedtuple("Temperature", ["label", "current", "high", "critical"])

log = logging.getLogger("glances_lhm")
_lock = threading.Lock()
_computer = None
_value = None
_value_time = float("-inf")
_retry_after = 0.0


def _open_computer():
    """Load the library and open the CPU. It loads the PawnIO driver."""
    import pythonnet

    pythonnet.load("netfx")
    import clr

    clr.AddReference(os.path.join(LIB_DIR, "LibreHardwareMonitorLib.dll"))
    from LibreHardwareMonitor.Hardware import Computer

    computer = Computer()
    computer.IsCpuEnabled = True
    computer.Open()
    atexit.register(computer.Close)
    return computer


def _read_tctl():
    """Return the Tctl value in degrees Celsius, or None if there is no sensor."""
    from LibreHardwareMonitor.Hardware import HardwareType, SensorType

    for hardware in _computer.Hardware:
        if hardware.HardwareType != HardwareType.Cpu:
            continue
        hardware.Update()
        for sensor in hardware.Sensors:
            if (
                sensor.SensorType == SensorType.Temperature
                and sensor.Name.startswith(SENSOR_PREFIX)
                and sensor.Value is not None
            ):
                return float(sensor.Value)
    return None


def sensors_temperatures():
    """Replace psutil.sensors_temperatures(): same output format as on Linux."""
    global _computer, _value, _value_time, _retry_after
    with _lock:
        now = time.monotonic()
        if now - _value_time >= CACHE_SECONDS:
            if now < _retry_after:
                return {}
            try:
                if _computer is None:
                    _computer = _open_computer()
                _value = _read_tctl()
                _value_time = now
            except Exception:
                log.exception("Cannot read the CPU temperature. Next try in %s s.", RETRY_SECONDS)
                _computer = None
                _value = None
                _retry_after = now + RETRY_SECONDS
                return {}
        if _value is None:
            return {}
        return {"k10temp": [Temperature(GLANCES_LABEL, _value, None, None)]}


psutil.sensors_temperatures = sensors_temperatures

if __name__ == "__main__":
    import glances

    glances.main()
