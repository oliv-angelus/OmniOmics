import psutil
import shutil

def get_system_info() -> dict:
    cpu_count = psutil.cpu_count(logical=True)
    cpu_percent = psutil.cpu_percent(interval=None)

    ram = psutil.virtual_memory()
    ram_total_gb = round(ram.total / (1024 ** 3), 1)
    ram_used_gb = round(ram.used / (1024 ** 3), 1)
    ram_percent = ram.percent

    disk = shutil.disk_usage("/")
    disk_total_gb = round(disk.total / (1024 ** 3), 1)
    disk_used_gb = round(disk.used / (1024 ** 3), 1)
    disk_free_gb = round(disk.free / (1024 ** 3), 1)

    return {
        "cpu": {
            "cores": cpu_count,
            "percent": cpu_percent,
        },
        "ram": {
            "total_gb": ram_total_gb,
            "used_gb": ram_used_gb,
            "percent": ram_percent,
        },
        "disk": {
            "total_gb": disk_total_gb,
            "used_gb": disk_used_gb,
            "free_gb": disk_free_gb,
        },
    }
