---
name: project-notes-system
description: OmniOmics keeps its own project history in notes/*.md — check and update these instead of relying on conversation memory
metadata: 
  node_type: memory
  type: reference
  originSessionId: 2c4945cb-0087-4c6a-bec6-0492ec4c53d9
---

The OmniOmics repo (`/home/angelo/Downloads/OmniOmics`) has a `notes/` folder that is the authoritative, human-curated project history — not this memory system. Key files:
- `notes/Decisions Log.md` — chronological, most-load-bearing decisions and real-bugs-found-and-fixed entries, dense and detailed, one section per piece of work.
- `notes/Known Issues and Next Steps.md` — current focus, open items, deliberate scope cuts, testing conventions learned.
- `notes/Project Overview.md`, `notes/<Pipeline>.md`, `notes/<Pipeline> Dependency Graph.md`, `notes/Pipeline Manifest Schema.md` — per-topic reference docs, cross-linked with `[[wikilink]]` style.

**How to apply**: before starting nontrivial work, skim relevant entries in `Known Issues and Next Steps.md` (open items, deliberate-not-a-bug cuts) so past decisions aren't redone or re-proposed. After finishing nontrivial work (a real bug fix, an architecture decision, a feature with a non-obvious rationale), the user's habit is to ask "salve nas notas" so they can clear the conversation — append a dense entry to `Decisions Log.md` (matching its existing voice: what was reported, root cause, fix, how it was verified, any known remaining limitation) and, if something is left open, a corresponding bullet in `Known Issues and Next Steps.md`. Don't duplicate this technical detail into this memory system's own project-type notes — the notes/ folder is the durable, greppable record; this memory system should only hold things about *collaborating with this user* that aren't captured there (see [[user_wants_efficient_verification]]).
