# Import libraries
import json
import os
import re
import requests
from jsonschema import Draft7Validator, validators

# Define file paths
cnf_pth = os.path.join(os.getcwd(), "Config.json")
dow_pth = os.path.join(os.getcwd(), "Programs")
ext_pth = os.path.join(os.getcwd(), "Programs")
ins_pth = os.path.join(os.getcwd(), "Programs")
lnk_pth = os.path.join(os.getcwd(), "Programs")

# Default configuration dictionary
default_config = {}

# Function to save configuration
def save_config(save_path, save_data):
    try:
        with open(save_path, 'w') as file:
            file.write(json.dumps(save_data, indent=4))
    except Exception as save_error:
        print(f"An error occurred while saving config: {save_error}")
        exit(1)

# Function to load configuration
def load_config(load_path):
    try:
        with open(load_path, 'r') as read:
            return json.load(read)
    except (FileNotFoundError, json.JSONDecodeError):
        save_config(load_path, default_config)
        return default_config
    except Exception as load_error:
        print(f"An error occurred while reading config: {load_error}")
        exit(1)

# Load configuration
data = load_config(cnf_pth)

# Process Paths and Programs sections
paths = data.setdefault('Paths', [])
if not paths:
    paths.append({})

for path in paths:
    if 'dow_pth' not in path:
        path.setdefault('dow_pth', dow_pth)
    if 'ext_pth' not in path:
        path.setdefault('ext_pth', ext_pth)
    if 'ins_pth' not in path:
        path.setdefault('ins_pth', ins_pth)
    if 'lnk_pth' not in path:
        path.setdefault('lnk_pth', lnk_pth)

programs = data.setdefault('Programs', [])
if not programs:
    programs.append({})

for program in programs:
    if 'url' not in program:
        program.setdefault('url', 'null')

metadata = data.setdefault('Metadata', {})

# Define JSON schema for validation
json_schema = {
    "type": "object",
    "properties": {
        "Paths": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "dow_pth": {
                        "type": ["string", "null"]
                    },
                    "ext_pth": {
                        "type": ["string", "null"]
                    },
                    "ins_pth": {
                        "type": ["string", "null"]
                    },
                    "lnk_pth": {
                        "type": ["string", "null"]
                    }
                },
                "required": ["dow_pth", "ext_pth", "ins_pth", "lnk_pth"]
            },
            "minItems": 1
        },
        "Programs": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "url": {
                        "type": ["string", "null"],
                        "format": "uri"
                    }
                },
                "required": ["url"]
            },
            "minItems": 1
        },
        "Metadata": {
            "type": "object",
            "additionalProperties": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "Hash": {"type": ["string", "null"]},
                        "ETag": {"type": ["string", "null"]},
                        "LMod": {"type": ["string", "null"]}
                    }
                }
            }
        }
    },
    "required": ["Paths", "Programs", "Metadata"]
}

# Create custom validator
def extend_validator(validator_class):
    try:
        validate_properties = validator_class.VALIDATORS["properties"]

        def remove_additional_properties(validator, properties, instance, schema):
            for prop in list(instance.keys()):
                if prop not in properties:
                    del instance[prop]
            for error in validate_properties(validator, properties, instance, schema):
                yield error

        return validators.extend(validator_class, {"properties": remove_additional_properties})
    except Exception as validator_error:
        print(f"An error occurred while validating config: {validator_error}")
        exit(1)

CustomValidator = extend_validator(Draft7Validator)
CustomValidator(json_schema).validate(data)

save_config(cnf_pth, data)

# Make folder function
def make_folder(make_folder_path):
    if not os.path.exists(make_folder_path):
        try:
            os.mkdir(make_folder_path)
        except Exception as make_folder_error:
            print(f"An error occurred while creating the folder: {make_folder_error}")
            exit(1)

# Remove folder function
def remove_folder(remove_folder_path):
    if os.path.exists(remove_folder_path):
        try:
            os.rmdir(remove_folder_path)
        except Exception as remove_folder_error:
            print(f"An error occurred while removing the folder: {remove_folder_error}")
            exit(1)

# Remove file function
def remove_file(remove_file_path):
    if os.path.exists(remove_file_path):
        try:
            os.remove(remove_file_path)
        except Exception as remove_file_error:
            print(f"An error occurred {remove_file_error}")
            exit(1)

# Text cleaning function
def clear_text(clean_text):
    return re.sub(r'[<>:"/\\|?*=&]', '', clean_text)

# import Path variables from config
for path in data['Paths']:
    dow_pth = path.get('dow_pth')
    ext_pth = path.get('ext_pth')
    ins_pth = path.get('ins_pth')
    lnk_pth = path.get('lnk_pth')

print(dow_pth)
print(ext_pth)
print(ins_pth)
print(lnk_pth)

# make folder
make_folder(dow_pth)
make_folder(ext_pth)
make_folder(ins_pth)
make_folder(lnk_pth)

# import Programs variables from config
for program in data['Programs']:
    dow_url = program.get('url')
    # get head request from url
    try:
        response = requests.head(dow_url, allow_redirects=True)
        response.raise_for_status()

        CD = response.headers.get('Content-Disposition')
        CT = response.headers.get('Content-Type')
        CL = response.headers.get('Content-Length')
        ET = response.headers.get('ETag')
        LM = response.headers.get('Last-Modified')

    except Exception as request_error:
        print(f"An error occurred while retrieving the URL: {request_error}")
        exit(1)

    ext = [".exe", ".zip", ".rar", ".iso"]

    # Define file name
    fle_nme = None
    if CD is not None:
        fle_nme = CD.split("filename=")[-1].strip('"')
    else:
        fle_nme = os.path.basename(dow_url)
        fle_nme = clear_text(fle_nme)
        # Define file extension
        if CT is not None:
            CT = "." + CT.split("/")[-1]
            if not fle_nme.endswith(tuple(ext)):
                if CT in ext:
                    fle_nme += CT

    if not fle_nme.endswith(tuple(ext)):
        print(f"'{fle_nme}' filename cannot be without an extension.")
        exit(1)

    fle_pth = os.path.join(dow_pth, fle_nme)

    # CL variable convert MB
    if CL is not None:
        MB = int(CL) / 1024
        MB = round(MB, 2)
    else:
        MB = None

    if ET is not None:
        ET = ET.strip('"')

    FH = None  # WIP

    print(dow_url)
    print(f"CD:{CD}")
    print(f"CT:{CT}")
    print(f"CL:{CL}")
    print(f"ET:{ET}")
    print(f"LM:{LM}")
    print(f"fle_nme:{fle_nme}")
    print(f"dow_pth:{fle_pth}")
    print(f"MB:{MB}")
    print(f"ETag:{ET}")

    Old_FH = None
    Old_ET = None
    Old_LM = None

    # if exist import Metadata variables from config
    if fle_nme in data['Metadata']:
        for meta in data['Metadata'][fle_nme]:
            if 'Hash' in meta:
                Old_FH = meta.get('Hash')
            if 'ETag' in meta:
                Old_ET = meta.get('ETag')
            if 'LMod' in meta:
                Old_LM = meta.get('LMod')

    # Check metadata difrencess
    diff = (FH != Old_FH) or (ET != Old_ET) or (LM != Old_LM)
    if diff:
        print(f"{fle_nme} update available. Downloading...")
        try:
            response = requests.get(dow_url)
            response.raise_for_status()
            with open(fle_pth, 'wb') as download:
                download.write(response.content)
                print(f"File '{fle_pth}' downloaded successfully!")
        except Exception as download_error:
            print(f"An error occurred while downloading file. {download_error}")
            exit(1)
        if os.path.exists(fle_pth):
            filedata = metadata.setdefault(fle_nme, [])
            if not filedata:
                filedata.append({})
            for meta in filedata:
                if 'Hash' not in meta:
                    meta.setdefault('Hash', FH)
                if 'ETag' not in meta:
                    meta.setdefault('ETag', ET)
                if 'LMod' not in meta:
                    meta.setdefault('LMod', LM)
            save_config(cnf_pth, data)
