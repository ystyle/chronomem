window.__insts = 0;
window.__instSids = [];
(function poll() {
  if (window.CangjieUI && !window.__patched) {
    window.__patched = 1;
    const O = window.CangjieUI;
    window.CangjieUI = class extends O {
      constructor(container, sessionId, initialTree) {
        window.__insts++;
        window.__instSids.push(sessionId);
        super(container, sessionId, initialTree);
      }
    };
  } else {
    setTimeout(poll, 30);
  }
})();
