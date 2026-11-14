window.waferAsyncRenderer = (function() {
  var pending = 0;
  var didNotify = false;

  function notifyContentReady() {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.waferContentReady
    ) {
      window.webkit.messageHandlers.waferContentReady.postMessage(document.querySelector('meta[name="wafer-navigation"]')?.content || "");
    }
  }

  function settleThenNotify() {
    if (pending > 0) {
      return;
    }
    function notifyOnce() {
      if (didNotify) {
        return;
      }
      didNotify = true;
      notifyContentReady();
    }

    setTimeout(notifyOnce, 0);
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(function() {
        requestAnimationFrame(notifyOnce);
      });
    }
  }

  return {
    beginTask: function() {
      pending += 1;
      var didFinish = false;
      return function() {
        if (didFinish) {
          return;
        }
        didFinish = true;
        pending = Math.max(pending - 1, 0);
        settleThenNotify();
      };
    }
  };
})();
