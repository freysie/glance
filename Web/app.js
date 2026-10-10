// Glance localhost viewer. Served statically (e.g. `python3 -m http.server 8888
// --directory Web`); signaling goes to the Glance app itself on :8899.
const API = "http://127.0.0.1:8899";
const statusEl = document.getElementById("status");
const videoEl = document.getElementById("v");
const retryEl = document.getElementById("retry");

const streamId = new URLSearchParams(location.search).get("stream");

function say(msg) {
  statusEl.textContent = msg;
  statusEl.hidden = false;
}

function hush() {
  statusEl.hidden = true;
  retryEl.hidden = true;
}

function waitGatheringComplete(pc) {
  if (pc.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("ICE gathering timed out")), 10000);
    pc.onicegatheringstatechange = () => {
      if (pc.iceGatheringState === "complete") {
        clearTimeout(timer);
        resolve();
      }
    };
  });
}

async function isLive() {
  try {
    const res = await fetch(`${API}/api/status?stream=${encodeURIComponent(streamId)}`);
    if (!res.ok) return false;
    const { live } = await res.json();
    return !!live;
  } catch {
    return false;
  }
}

async function negotiate() {
  say(`Connecting to stream ${streamId}…`);
  videoEl.style.visibility = "hidden";
  let shown = false;
  const showVideo = () => {
    if (shown) return;
    shown = true;
    videoEl.style.visibility = "visible";
    hush();
  };
  const pc = new RTCPeerConnection({ iceServers: [] });
  pc.ontrack = (e) => {
    videoEl.srcObject = e.streams[0];
    // First *presented* frame, not metadata: guarantees real pixels on screen.
    if ("requestVideoFrameCallback" in videoEl) {
      videoEl.requestVideoFrameCallback(() => showVideo());
    } else {
      videoEl.onresize = () => {
        if (videoEl.videoWidth > 0) showVideo();
      };
    }
    // Safety net in case callbacks never fire.
    setTimeout(() => showVideo(), 4000);
  };
  pc.onconnectionstatechange = () => {
    if (pc.connectionState === "failed") {
      say("Connection failed — is the Glance app still recording?");
      retryEl.hidden = false;
    }
  };

  pc.addTransceiver("video", { direction: "recvonly" });
  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  await waitGatheringComplete(pc);

  let res;
  try {
    res = await fetch(`${API}/api/offer`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ stream: streamId, sdp: pc.localDescription.sdp, type: "offer" }),
    });
  } catch (e) {
    say("Cannot reach the Glance app on :8899 — is it running and recording?");
    retryEl.hidden = false;
    pc.close();
    return;
  }
  if (!res.ok) {
    say(`App said no (HTTP ${res.status}) — stream over or wrong id?`);
    retryEl.hidden = false;
    pc.close();
    return;
  }
  const answer = await res.json();
  await pc.setRemoteDescription(answer);
  window.__glancePc = pc;
}

async function main() {
  if (!streamId) {
    say("No ?stream=id in the URL — open this page from the link in the Glance app.");
    return;
  }
  retryEl.onclick = () => {
    retryEl.hidden = true;
    if (window.__glancePc) window.__glancePc.close();
    // Drop the stale frozen frame immediately; negotiate() re-shows on live frames.
    videoEl.style.visibility = "hidden";
    videoEl.srcObject = null;
    main();
  };
  say(`Waiting for stream ${streamId} to go live…`);
  for (;;) {
    if (await isLive()) break;
    await new Promise((r) => setTimeout(r, 2000));
  }
  await negotiate();
}

main();
