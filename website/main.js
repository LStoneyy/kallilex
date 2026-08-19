(function () {
  "use strict";

  var REDUCED_MOTION = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* 1. Latest release ---------------------------------------------------- */

  function loadLatestRelease() {
    fetch("https://api.github.com/repos/LStoneyy/kallilex/releases/latest")
      .then(function (res) {
        if (!res.ok) throw new Error("no release yet");
        return res.json();
      })
      .then(function (data) {
        var assets = data.assets || [];
        var pattern = /^Kallilex-v.+-macos-universal\.zip$/;
        var asset = null;
        for (var i = 0; i < assets.length; i++) {
          if (pattern.test(assets[i].name)) {
            asset = assets[i];
            break;
          }
        }
        if (!asset) throw new Error("no matching asset");

        var downloadLinks = document.querySelectorAll("[data-download]");
        for (var j = 0; j < downloadLinks.length; j++) {
          downloadLinks[j].href = asset.browser_download_url;
        }

        var versionEls = document.querySelectorAll("[data-version]");
        for (var k = 0; k < versionEls.length; k++) {
          versionEls[k].textContent = data.tag_name;
          versionEls[k].hidden = false;
        }
      })
      .catch(function () {
        // Expected initial state: only a draft release exists, API returns 404.
        // Leave the default href pointing at the releases page and hide version tags.
      });
  }

  /* 2. Brew expander + copy buttons --------------------------------------- */

  function initBrewToggle() {
    var toggles = document.querySelectorAll("[data-brew-toggle]");
    toggles.forEach(function (toggle) {
      var panelId = toggle.getAttribute("aria-controls");
      var panel = panelId ? document.getElementById(panelId) : null;
      if (!panel) return;

      toggle.addEventListener("click", function () {
        var expanded = toggle.getAttribute("aria-expanded") === "true";
        toggle.setAttribute("aria-expanded", String(!expanded));
        panel.setAttribute("aria-hidden", String(expanded));
        panel.toggleAttribute("inert", expanded);
      });
    });
  }

  function initCopyButtons() {
    var buttons = document.querySelectorAll("[data-copy]");
    buttons.forEach(function (button) {
      button.addEventListener("click", function () {
        var text = button.getAttribute("data-copy");
        if (!text || !navigator.clipboard || !navigator.clipboard.writeText) return;

        navigator.clipboard
          .writeText(text)
          .then(function () {
            var original = button.textContent;
            button.textContent = "Copied";
            setTimeout(function () {
              button.textContent = original;
            }, 1500);
          })
          .catch(function () {
            /* clipboard write failed silently; nothing to do */
          });
      });
    });
  }

  /* 3. Scroll reveal -------------------------------------------------------- */

  function initScrollReveal() {
    var targets = document.querySelectorAll("[data-reveal]");
    if (!targets.length) return;

    if (REDUCED_MOTION || typeof IntersectionObserver === "undefined") {
      targets.forEach(function (el) {
        el.classList.add("is-visible");
      });
      return;
    }

    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.2 }
    );

    targets.forEach(function (el) {
      observer.observe(el);
    });
  }

  /* 4. Video fallback --------------------------------------------------------- */

  function initDemoVideo() {
    var video = document.querySelector(".demo__sticky video");
    if (!video || REDUCED_MOTION) return;

    function tryPlay() {
      video.play().catch(function () {
        /* autoplay blocked or source missing; poster background stays visible */
      });
    }

    tryPlay();

    // Low Power Mode and Safari's "Never Auto-Play" block play() without a
    // user gesture; the first interaction lifts that restriction.
    function onFirstGesture() {
      if (video.paused) tryPlay();
      window.removeEventListener("pointerdown", onFirstGesture);
      window.removeEventListener("touchend", onFirstGesture);
      window.removeEventListener("keydown", onFirstGesture);
    }
    window.addEventListener("pointerdown", onFirstGesture);
    window.addEventListener("touchend", onFirstGesture);
    window.addEventListener("keydown", onFirstGesture);
  }

  document.addEventListener("DOMContentLoaded", function () {
    loadLatestRelease();
    initBrewToggle();
    initCopyButtons();
    initScrollReveal();
    initDemoVideo();
  });
})();
