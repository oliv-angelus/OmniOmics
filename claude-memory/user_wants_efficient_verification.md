---
name: user-wants-efficient-verification
description: "User gets impatient with prolonged live-UI verification/narration once a fix is plausibly done — prefer fast, targeted verification and concise updates"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 2c4945cb-0087-4c6a-bec6-0492ec4c53d9
---

After a bug fix, the user pushed back mid-verification with "OQUE VOCE AINDA ESTA FAZENDO? o problema ja foi resolvido" (what are you still doing, the problem's already solved) while a long live-app UI testing session (building the Flutter app, launching under XWayland, screenshotting, clicking through screens with xdotool) was still running.

**Why**: OmniOmics's frontend is a Flutter desktop app — building + launching + driving it with screenshots/xdotool is slow and highly visible turn-by-turn (lots of tool calls, each narrated). The user would rather get the fix and a concise explanation than watch an extended manual QA pass, especially once the fix is well-reasoned/covered by faster verification.

**How to apply**: for backend/logic bugs in this repo, prefer writing a targeted integration test (e.g. spin up the real `uvicorn` app in a background thread, drive it with the real client library — see [[project_notes_system]] / `Known Issues and Next Steps.md`'s testing-conventions section for the exact recipe and the `TestClient` pitfall to avoid) over a full manual UI click-through. Reserve live-app UI driving for when the bug is specifically UI/rendering-shaped and can't be verified another way, and even then keep it tight — verify the one thing in question, then stop and report, rather than continuing to explore adjacent flows. Keep end-of-turn summaries short regardless of how much verification happened underneath.
