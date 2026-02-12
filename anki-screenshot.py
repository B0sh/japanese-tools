"""
Instlation instructions

## cd to installation folder
cd ~/japanese-tools


## Create venv
python3 -m venv .venv     
source .venv/bin/activate
python3 -m pip install -r requirements.tx
"""

from PIL import Image
import requests
import json
import sys
import os
import uuid
from subprocess import Popen
from datetime import datetime, timedelta

def notify(title, text):
    if sys.platform == 'darwin': 
        os.system("""
                osascript -e 'display dialog "{}" with title "{}"'
                """.format(text, title))

if sys.platform == 'win32':
    mac = False
    collection_path = os.path.expanduser('~/AppData/Roaming/Anki2/User 1/collection.media')
elif sys.platform == 'darwin':
    mac = True
    collection_path = os.path.expanduser('~/Library/Application Support/Anki2/User 1/collection.media')
    import subprocess

    def asrun(ascript):
        "Run the given AppleScript and return the standard output."

        osa = subprocess.run(['/usr/bin/osascript', '-'], input=ascript, text=True, capture_output=True)
        if osa.returncode == 0:
            return osa.stdout.rstrip()
        else:
            raise ChildProcessError(f'AppleScript: {osa.stderr.rstrip()}')


    def asquote(astr):
        "Return the AppleScript equivalent of the given string."

        astr = astr.replace('"', '" & quote & "')
        return '"{}"'.format(astr)

else:
    raise "Platform not supported"

server = 'http://127.0.0.1:8765'

response = requests.post(server, json = {
    'action': 'getMediaDirPath',
    'version': 6,
})

if response:
    result = json.loads(response.text)
    if result['result'] and os.path.exists(result['result']):
        collection_path = result['result']
        print("Collection path: ", collection_path)
    else:
        raise "Media folder not found"
    

response = requests.post(server, json = {
    'action': 'findNotes',
    'version': 6,
    'params': {
        'query': 'added:1'
    }
})

result = json.loads(response.text)
if result['result']:
    recentNotes = result['result']
    noteId = max(result['result'])
else: 
    raise "No latest note found"

print("Latest Anki Note ID:", noteId)


response = requests.post(server, json = {
    'action': 'notesInfo',
    'version': 6,
    'params': {
        'notes': [ noteId ]
    }
})
result = json.loads(response.text)
if result['result']:
    if result['result'][0]['fields']['Picture']['value']:
        notify('Anki Screenshot', 'A picture already exists on the latest Anki Card')

        response = requests.post(server, json = {
            'action': 'guiBrowse',
            'version': 6,
            'params': {
                'query': 'added:1'
            }
        })


        exit()
        
        """
        print("card picture already present; GUI Not working")
 
        title = "B0sh's Famous Card Picker"

        msg = "A picture already exists on the latest Anki Card"


        recentNotes.sort(reverse=True)
        response = requests.post(server, json = {
            'action': 'notesInfo',
            'version': 6,
            'params': {
                'notes': recentNotes
            }
        })

        result = json.loads(response.text)
        cards = []
        if result['result']:
            for x in result['result']:
                cards.append(str(x['noteId']) + "; " + x['fields']['Expression']['value'])

        response = easygui.choicebox(msg, title, cards)
        if response == None:
            print("Cancelled")
            exit()
            pass
        else:
            noteId = int(response.split(';')[0])
            print(noteId)

        """

    else:
        print("No picture foudn, proceed as normal")
else:
    print("no latest note found, skipping existing content check")





recent_images = []
card_image = ""

for potential_image_folders in [ '~/Downloads', '~/Desktop' ]:
    potential_image_dir = os.path.expanduser(potential_image_folders)
    potential_images = [f for f in os.listdir(potential_image_dir) if (f.endswith('.jpg') or f.endswith('.png'))]

    for image in [f for f in potential_images if (datetime.now() - datetime.fromtimestamp(os.path.getctime(os.path.join(potential_image_dir, f)))) <= timedelta(minutes=3)]:
        recent_images.append(f'{potential_image_dir}/{image}')
    



if not recent_images:
    if mac:
        os.chdir(collection_path)
        card_image = f'Screenshot Mac {datetime.now().strftime("%Y-%m-%d %H-%M-%S")}.jpg'
        print("Taking screenshot: ", card_image)
        
        # Broken Macos 15 :( 
        os.system(f'screencapture -tjpg -i "{card_image}"')
        # notify('Anki Screenshot', 'Screenshots broken in MacOS 15')
        # exit()
    else:
        print(" Take Screenshot ")

        # regular share x workflow from here
        os.chdir(f'C:\\Program Files\\ShareX')
        os.system('ShareX.exe -workflow "Anki Screenshot"')
else:
    print("");
    print("Found potential images: ", recent_images)

    original_image = recent_images[0]
    card_image = os.path.basename(original_image)

    # automatically convert PNG to JPG
    if os.path.splitext(original_image)[1] == '.png':
        png_image = Image.open(original_image)
        png_image = png_image.convert('RGB')
        png_image.save(os.path.splitext(original_image)[0] + '.jpg', format='JPEG', quality=80)
        original_image = os.path.splitext(original_image)[0] + '.jpg'
        card_image = os.path.basename(original_image)
        print(f'Converted PNG to JPG: {card_image}')

        os.remove(recent_images[0])

    if os.path.splitext(original_image)[1] == '.jpg':

        print(f'Found image: {card_image}')

        if os.path.exists(f'{collection_path}/{card_image}'):
            card_image = f'{card_image[:-4]}-{str(uuid.uuid4())[0:8]}.jpg'
            print(f'Renamed to {card_image}')
        anki_file = f'{collection_path}/{card_image}'

        os.rename(original_image, anki_file)





if card_image and os.path.exists(f'{collection_path}/{card_image}'):
    response = requests.post(server, json = {
        'action': 'guiBrowse',
        'version': 6,
        'params': {
            'query': 'nid:666'
        }
    })
    print("guiBrowse result", response.text)

    updateDto = {
        'action': 'updateNoteFields',
        'version': 6,
        'params': {
            'note': {
                'id': noteId,
                'fields': {
                    'Picture': f'<img src=\"{card_image}\">'
                }
            }
        }
    }

    if mac:
        # Optional code that look at the current open tab only in chrome and updates the 
        # AnkiCard url and document title for my personal records. The purpose is
        # sometimes I look up words that I hear in videos and can't use yomichan to 
        # get the data. (this is super fun)
        activeTab = asrun('''
            tell application "Google Chrome"
                if 0 < (count of windows) then
                    tell front window
                        { title } of active tab
                    end tell
                else
                    "No windows open in Chrome"
                end if
            end tell
        ''')

        activeURL = asrun('''
            tell application "Google Chrome"
                if 0 < (count of windows) then
                    tell front window
                        { URL } of active tab
                    end tell
                else
                    "No windows open in Chrome"
                end if
            end tell
        ''')
        print("Tab Title: ", activeTab)
        print("Tab URL: ", activeURL)
        
        if activeTab != "No windows open in Chrome" and (
            "youtube.com" in activeURL or "twitch.tv" in activeURL
        ):
            updateDto['params']['note']['fields']['URL'] = f'<a href="{activeURL}">{activeURL}</a>'
            updateDto['params']['note']['fields']['DocumentTitle'] = activeTab


    response = requests.post(server, json = updateDto)
    print("update result", response.text)


    response = requests.post(server, json = {
        'action': 'guiBrowse',
        'version': 6,
        'params': {
            'query': f'nid:{noteId}'
        }
    })
    print("guiBrowse result", response.text)
else:
    print("Image not found, no update was made")
