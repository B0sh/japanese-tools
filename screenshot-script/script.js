// ==UserScript==
// @name         Video Screenshot Button
// @version      1.4.0
// @description  Screenshots videos from any website with a <video> element, including iframes.
// @match        *://*/*
// @grant        none
// @require      https://cdn.jsdelivr.net/npm/@violentmonkey/shortcut@1
// @run-at       document-start
// ==/UserScript==

if (window.trustedTypes && window.trustedTypes.createPolicy) {
    window.trustedTypes.createPolicy('default', {
        createHTML: (string, sink) => string
    });
}

console.log("SCREENSHOT SCRIPT LOADED", window.location.href);

function getVideoPlayer() {
    // Finds the first video element in the current document (main or iframe).
    return document.querySelector('video');
}

function screenshot() {
    const player = getVideoPlayer();
    if (!player) {
        console.log("No video element found to screenshot in this context.");
        return;
    }

    const canvas = document.createElement("canvas");
    canvas.width = player.videoWidth;
    canvas.height = player.videoHeight;
    canvas.getContext('2d').drawImage(player, 0, 0, canvas.width, canvas.height);

    const seconds = Math.floor(player.currentTime % 60).toString().padStart(2, '0');
    const minutes = Math.floor((player.currentTime / 60) % 60).toString().padStart(2, '0');
    const hours = Math.floor((player.currentTime / 3600)).toString();

    let time = `${minutes}-${seconds}`;
    if (hours > 0) {
      time = `${hours}-${time}`;
    }

    const screenshotFormat = "jpeg";
    // When run in an iframe, document.title will be the iframe's title.
    const title = `${document.title}_${time}.jpg`;

    const downloadLink = document.createElement("a");
    downloadLink.download = title;

    canvas.toBlob(function(blob) {
      downloadLink.href = URL.createObjectURL(blob);
      downloadLink.click();
      URL.revokeObjectURL(downloadLink.href);
    }, 'image/' + screenshotFormat);
}

// Handles commands for video manipulation.
function handleCommand(command) {
    const player = getVideoPlayer();
    if (!player) return; // No video in this context (e.g., an ad iframe).

    switch (command) {
        case 'screenshot':
            screenshot();
            break;
        case 'seek-backward-1':
            player.currentTime -= 1;
            break;
        case 'seek-forward-1':
            player.currentTime += 1;
            break;
        case 'seek-backward-5':
            player.currentTime -= 5;
            break;
        case 'seek-forward-5':
            player.currentTime += 5;
            break;
    }
}

// --- Main Logic ---

// Top-level window registers shortcuts and broadcasts to iframes.
if (window.self === window.top) {
    console.log("Running in top window, registering shortcuts.");

    const broadcastCommand = (command) => {
      console.log(`Broadcasting command: ${command} to all iframes and self.`);
      console.log("player", getVideoPlayer());

        // Execute the command on the main page itself.
        handleCommand(command);

        // Broadcast the command to all iframes.
        document.querySelectorAll('iframe').forEach(iframe => {
            iframe.contentWindow.postMessage({ scriptCommand: command }, '*');
        });
    };

    VM.shortcut.register('ctrl-left', () => broadcastCommand('seek-backward-1'));
    VM.shortcut.register('ctrl-right', () => broadcastCommand('seek-forward-1'));
    VM.shortcut.register('alt-left', () => broadcastCommand('seek-backward-5'));
    VM.shortcut.register('alt-right', () => broadcastCommand('seek-forward-5'));
    VM.shortcut.register('ctrl-s', () => broadcastCommand('screenshot'));
}

// All windows (top and iframes) listen for commands.
window.addEventListener('message', (event) => {
    // Ensure the message is from our script and not a random message.
    if (event.data && event.data.scriptCommand) {
        console.log(`Received command: ${event.data.scriptCommand} in`, window.location.href);
        handleCommand(event.data.scriptCommand);
    }
});