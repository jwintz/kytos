✦ The lack of keyboard focus when running kytos via pixi run is primarily caused
  by a timing race condition during session restoration, which is triggered by
  the run task's aggressive cleanup of the pane server.

  Root Cause Analysis


   1. Forced Slow Path via Server Killing: The pixi run command explicitly kills
      the pane server daemon (kill $(cat .../pane.pid)). Consequently, when the
      app launches, KytosAppModel's reconciliation process finds that all
      persisted session IDs are dead and clears them. This forces every terminal
      pane to create a new session from scratch.
   2. Serialized and Delayed Initialization: Session creation is serialized by
      KytosTerminalManager using a global lock (globalCreationInFlight). Each
      pane must wait for the pane server to restart (since it was killed) and
      for its specific session to be created. This can take several seconds in a
      multi-pane setup.
   3. Late View Mounting: The TerminalView is only added to the SwiftUI
      hierarchy after its session is ready (paneInitDone = true). Because this
      happens asynchronously and sequentially, the terminal views appear at
      different times, often long after the main window has opened.
   4. Brittle Focus Timing: The focus logic in
      KytosTerminalManager.getOrCreateTerminal uses fixed delays (0.15s and
      0.35s) to call makeFirstResponder. If these fire before the window has
      fully settled as the "key" window, or while other UI components (like the
      Kelyphos sidebars) are still initializing and potentially claiming focus,
      the terminal fails to become the first responder.
   5. Focus Competition: In restored "previous states" with multiple panes, each
      pane independently attempts to claim focus when it finally mounts. The
      sequential nature of their creation, combined with the slow startup forced
      by pixi run, makes it highly likely that the final focus state is either
      non-deterministic or lost to a different UI element.


  Summary of Diagnosis
  The issue is not a bug in focus handling itself, but a lifecycle mismatch. The
  pixi run script destroys the state that the app expects to find, causing a
  slow, serialized recovery process that pushes terminal initialization past the
  window's "focus-ready" period. This is further complicated by the fact that
  open -W might not immediately grant "key" status to the window if the user's
  attention returns to the terminal where they launched the command.
