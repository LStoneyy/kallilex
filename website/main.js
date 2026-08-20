(function () {
  "use strict";

  var REDUCED_MOTION = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* 1. Latest release ---------------------------------------------------- */

  function findAsset(assets, pattern) {
    for (var i = 0; i < assets.length; i++) {
      if (pattern.test(assets[i].name)) return assets[i];
    }
    return null;
  }

  function wireAssetLinks(selector, asset) {
    if (!asset) return; // no matching asset: leave the link on its releases-page default
    var links = document.querySelectorAll(selector);
    for (var j = 0; j < links.length; j++) {
      links[j].href = asset.browser_download_url;
    }
  }

  function loadLatestRelease() {
    fetch("https://api.github.com/repos/LStoneyy/kallilex/releases/latest")
      .then(function (res) {
        if (!res.ok) throw new Error("no release yet");
        return res.json();
      })
      .then(function (data) {
        var assets = data.assets || [];

        var macAsset = findAsset(assets, /^Kallilex-v.+-macos-universal\.zip$/);
        var debAsset = findAsset(assets, /^Kallilex-v.+-linux-x86_64\.deb$/);
        var rpmAsset = findAsset(assets, /^Kallilex-v.+-linux-x86_64\.rpm$/);
        var appImageAsset = findAsset(assets, /^Kallilex-v.+-linux-x86_64\.AppImage$/);

        if (!macAsset && !debAsset && !rpmAsset && !appImageAsset) {
          throw new Error("no matching asset");
        }

        // The primary [data-download] buttons (hero + install card) point at
        // whichever asset matches the OS upgradeDownloadButtons() already
        // detected for them; anything unresolved keeps its releases-page default.
        var primaryButtons = document.querySelectorAll("[data-download]");
        for (var p = 0; p < primaryButtons.length; p++) {
          var button = primaryButtons[p];
          var isLinuxButton = button.getAttribute("data-download-os") === "linux";
          var primaryAsset = isLinuxButton ? debAsset : macAsset;
          if (primaryAsset) button.href = primaryAsset.browser_download_url;
        }

        wireAssetLinks("[data-download-deb]", debAsset);
        wireAssetLinks("[data-download-rpm]", rpmAsset);
        wireAssetLinks("[data-download-appimage]", appImageAsset);

        var versionEls = document.querySelectorAll("[data-version]");
        for (var k = 0; k < versionEls.length; k++) {
          versionEls[k].textContent = data.tag_name;
          versionEls[k].hidden = false;
        }
      })
      .catch(function () {
        // Expected initial state: only a draft release exists, API returns 404.
        // Leave the default hrefs pointing at the releases page and hide version tags.
      });
  }

  /* 2. OS-aware download buttons ------------------------------------------ */

  function isLinuxUserAgent(ua) {
    ua = ua || (typeof navigator !== "undefined" ? navigator.userAgent : "") || "";
    // Android and ChromeOS user agents also contain "Linux"; exclude both so
    // only genuine Linux desktop sessions get the Linux default.
    if (!/Linux/.test(ua)) return false;
    if (/Android/.test(ua)) return false;
    if (/CrOS/.test(ua)) return false;
    return true;
  }

  function upgradeDownloadButtons() {
    if (!isLinuxUserAgent()) return; // keep the default macOS label + href

    var buttons = document.querySelectorAll("[data-download]");
    buttons.forEach(function (button) {
      button.setAttribute("data-download-os", "linux");
      var label = button.querySelector("[data-download-label]");
      if (label) label.textContent = "Download for Linux";
    });
  }

  /* 3. Brew expander + copy buttons --------------------------------------- */

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

  /* 4. Scroll reveal -------------------------------------------------------- */

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

  /* 5. Video fallback --------------------------------------------------------- */

  function initDemoVideo() {
    var video = document.querySelector(".demo__sticky video");
    if (!video) return;

    var toggle = document.querySelector("[data-video-toggle]");
    var userPaused = false;

    function tryPlay() {
      video.play().catch(function () {
        /* autoplay blocked or source missing; poster background stays visible */
      });
    }

    function syncToggle() {
      if (!toggle) return;
      toggle.classList.toggle("is-paused", video.paused);
      toggle.setAttribute(
        "aria-label",
        video.paused ? "Play background video" : "Pause background video"
      );
    }

    tryPlay();

    // Low Power Mode and Safari's "Never Auto-Play" block play() without a
    // user gesture; the first interaction lifts that restriction.
    function onFirstGesture() {
      if (video.paused && !userPaused) tryPlay();
      window.removeEventListener("pointerdown", onFirstGesture);
      window.removeEventListener("touchend", onFirstGesture);
      window.removeEventListener("keydown", onFirstGesture);
    }
    window.addEventListener("pointerdown", onFirstGesture);
    window.addEventListener("touchend", onFirstGesture);
    window.addEventListener("keydown", onFirstGesture);

    if (toggle) {
      toggle.addEventListener("click", function () {
        if (video.paused) {
          userPaused = false;
          tryPlay();
        } else {
          userPaused = true;
          video.pause();
        }
      });
      video.addEventListener("play", syncToggle);
      video.addEventListener("pause", syncToggle);
      syncToggle();
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    upgradeDownloadButtons();
    loadLatestRelease();
    initBrewToggle();
    initCopyButtons();
    initScrollReveal();
    initDemoVideo();
  });
})();
