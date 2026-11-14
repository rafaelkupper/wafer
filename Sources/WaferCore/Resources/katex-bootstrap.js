(function() {
  var finishMathRender = window.waferAsyncRenderer.beginTask();

  function messageFor(error) {
    if (!error) {
      return 'Unknown KaTeX render error.';
    }
    if (typeof error === 'string') {
      return error;
    }
    return error.message || String(error);
  }

  function showError(block, message) {
    block.classList.add('has-error');
    block.classList.remove('is-rendered');

    var output = block.querySelector('.md-math-output');
    if (output) {
      output.replaceChildren();
    }

    var error = block.querySelector('.md-math-error');
    if (error) {
      error.hidden = false;
      error.textContent = 'Unable to render math: ' + message;
    }
  }

  var blocks = Array.prototype.slice.call(document.querySelectorAll('.md-math-display'));
  if (blocks.length === 0) {
    finishMathRender();
    return;
  }

  if (!window.katex || typeof window.katex.render !== 'function') {
    blocks.forEach(function(block) {
      showError(block, 'The bundled KaTeX renderer is unavailable.');
    });
    finishMathRender();
    return;
  }

  var errorColor = window.getComputedStyle(document.documentElement)
    .getPropertyValue('--mermaid-error-text-color')
    .trim() || '#cc0000';

  function renderBlock(block) {
    var source = block.querySelector('.md-math-source code');
    var output = block.querySelector('.md-math-output');
    if (!source || !output) {
      showError(block, 'The math container is missing required markup.');
      return;
    }

    try {
      window.katex.render(source.textContent || '', output, {
        displayMode: true,
        throwOnError: false,
        errorColor: errorColor
      });

      var error = block.querySelector('.md-math-error');
      if (error) {
        error.hidden = true;
        error.textContent = '';
      }
      block.classList.add('is-rendered');
      block.classList.remove('has-error');
    } catch (error) {
      showError(block, messageFor(error));
    }
  }

  blocks.forEach(renderBlock);
  // Edit-mode preview: render math blocks inserted by an in-place body patch.
  window.waferRenderMathBlocks = function(newBlocks) {
    newBlocks.forEach(renderBlock);
  };

  finishMathRender();
})();
