import re
import os

hdl_pattern = re.compile(r'"([^"]+)"')

with open("./scripts_user/config_script.tcl", "r") as config_file:
    config_lines =  config_file.readlines()

hdl_design = None

for line in config_lines:
    if "set hdl_file" in line:
        match = hdl_pattern.search(line)
        if match:
            hdl_design = match.group(1)
            break

# File paths
input_file = f"./innovus/{hdl_design}/cadence_45nm/timing_reports/req_timing.txt"  # Replace with the actual file path

# Open and read the file
with open(input_file, "r") as file:
    lines = file.readlines()

# Initialize empty lists to store the extracted values
arc_list = []
cell_list = []
instance_list = []
pin1_list = []
pin2_list = []
ip_inst_pin = []
op_inst_pin = []
# Regular expression to match the desired columns (Arc, Cell, and Instance)
pattern = re.compile(r'\| ([^|]+) \| ([^|]+) \| ([^|]+) \|')
arc_pattern = re.compile(r'(\w+)\s*(\^|v|0)?\s*(->\s+(\w+)\s*(\^|v|0)?)?')

tab_pattern = re.compile(r'\+[-]+(\+)$')

flag = 0
idx = 0

# Initialize counter for generating unique filenames
file_counter = 1

# Iterate over each line in the file
for line in lines:
    stripped_line = line.strip()
    
    if tab_pattern.search(stripped_line):
        if flag == 1:
            flag = not flag
            idx = idx + 1
            output_dir = f"./innovus/{hdl_design}/cadence_45nm/timing_reports/paths/"
            output_filename = f"{output_dir}path_{file_counter}.txt"
            
            if not os.path.exists(output_dir):
                os.makedirs(output_dir)
            # print(pin1_list)
            with open(output_filename, "w") as output_file:
                arc_list = arc_list[1:]
                cell_list = cell_list[2:]
                instance_list = instance_list[1:]
                pin1_list = pin1_list[1:]
                pin2_list = pin2_list[1:]
                ip_inst_pin = ip_inst_pin[1:]
                op_inst_pin = op_inst_pin[1:]
                
                for pins in zip(op_inst_pin[1:], ip_inst_pin[2:]):
                    output_file.write(f"{pins[0]} {pins[1]}\n")
                # Increment file_counter to ensure unique filenames
                file_counter += 1
            
            # Reset the lists for the next set of arcs
            arc_list = []
            cell_list = []
            instance_list = []
            pin1_list = []
            pin2_list = []
            ip_inst_pin = []
            op_inst_pin = []
        else:
            flag = 1

    if flag == 1:
        match = pattern.search(line)
        if match:
            arc, cell, instance = match.groups()
            arc_list.append(arc.strip())
            arc_match = arc_pattern.search(arc.strip())
            if arc_match:
                pin1_list.append(arc_match.group(1) if arc_match.group(1) else "0")
                pin2_list.append(arc_match.group(4) if arc_match.group(4) else "0")
                ip_inst_pin.append(f"{instance.strip()}/{arc_match.group(1)}")
                op_inst_pin.append(f"{instance.strip()}/{arc_match.group(4)}")
            cell_list.append(cell.strip())
            instance_list.append(instance.strip())

# try:
#     os.remove("./test_scripts/path_reports/paths/path0.txt")
#     print("path0.txt has been removed successfully.")
# except FileNotFoundError:
#     print("path0.txt does not exist.")

exit()

