from trench_ui import f, ms, get_hms, rect, Path
def main():
    print(f(3.14159, 2), f(-0.5, 1), f(1234.0, 0))
    print(ms(3.1812), get_hms(102.0*3600.0 + 45.0*60.0 + 40.0))
