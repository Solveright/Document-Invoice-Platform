/* ==========================================================================
 * Document & Invoice Platform — frontend
 *
 * No build step, no framework, no dependencies. Two things happen here:
 *
 *   1. Auth. We call the Cognito Identity Provider API directly over HTTPS
 *      (InitiateAuth with USER_PASSWORD_AUTH) and keep the resulting IdToken.
 *      That token goes in the Authorization header on every API call, where
 *      the API Gateway JWT authorizer verifies it.
 *
 *   2. Upload. POST /documents returns a short-lived presigned S3 URL. The
 *      browser PUTs the file straight to S3. Bytes never touch Lambda.
 *
 * Security notes worth knowing (see README for the full list):
 *   - USER_PASSWORD_AUTH sends the password to Cognito over TLS rather than
 *     using SRP. Fine for a learning project; SRP needs amazon-cognito-identity-js.
 *   - Tokens live in sessionStorage, which is readable by any XSS on this
 *     origin. A production app would use the hosted UI + auth code + PKCE.
 * ======================================================================= */

(function () {
  "use strict";

  var CFG = window.APP_CONFIG || {};
  var MAX_BYTES = CFG.maxUploadBytes || 20 * 1024 * 1024;
  var STORE_KEY = "dip.session";

  /* -------------------------------------------------------------- helpers */

  var $ = function (id) { return document.getElementById(id); };

  function show(el, visible) {
    if (el) { el.hidden = !visible; }
  }

  function setText(el, text) {
    if (el) { el.textContent = text; }
  }

  function formatBytes(bytes) {
    if (bytes === null || bytes === undefined) { return "—"; }
    if (bytes < 1024) { return bytes + " B"; }
    var units = ["KB", "MB", "GB"];
    var value = bytes / 1024;
    var i = 0;
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
    return value.toFixed(value >= 10 ? 0 : 1) + " " + units[i];
  }

  function formatDate(iso) {
    if (!iso) { return ""; }
    var d = new Date(iso);
    return isNaN(d.getTime()) ? iso : d.toLocaleString();
  }

  function decodeJwt(token) {
    try {
      var payload = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
      var padded = payload + "===".slice((payload.length + 3) % 4);
      return JSON.parse(atob(padded));
    } catch (e) {
      return null;
    }
  }

  /* -------------------------------------------------------------- session */

  var session = null;

  function loadSession() {
    try {
      var raw = sessionStorage.getItem(STORE_KEY);
      if (!raw) { return null; }
      var parsed = JSON.parse(raw);
      var claims = decodeJwt(parsed.idToken);
      // exp is seconds since epoch; drop the session 30s early to avoid
      // firing a request that expires in flight.
      if (!claims || !claims.exp || claims.exp * 1000 < Date.now() + 30000) {
        sessionStorage.removeItem(STORE_KEY);
        return null;
      }
      parsed.claims = claims;
      return parsed;
    } catch (e) {
      return null;
    }
  }

  function saveSession(authResult) {
    var claims = decodeJwt(authResult.IdToken);
    session = {
      idToken: authResult.IdToken,
      accessToken: authResult.AccessToken,
      claims: claims
    };
    sessionStorage.setItem(STORE_KEY, JSON.stringify({
      idToken: session.idToken,
      accessToken: session.accessToken
    }));
    return session;
  }

  function clearSession() {
    session = null;
    sessionStorage.removeItem(STORE_KEY);
  }

  /* ---------------------------------------------------------------- cognito */

  function cognitoCall(target, payload) {
    var endpoint = "https://cognito-idp." + CFG.region + ".amazonaws.com/";

    return fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-amz-json-1.1",
        "X-Amz-Target": "AWSCognitoIdentityProviderService." + target
      },
      body: JSON.stringify(payload)
    }).then(function (res) {
      return res.json().then(function (data) {
        if (!res.ok) {
          var type = (data.__type || "").split("#").pop();
          var err = new Error(data.message || type || "Authentication failed.");
          err.code = type;
          throw err;
        }
        return data;
      });
    });
  }

  function initiateAuth(username, password) {
    return cognitoCall("InitiateAuth", {
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: CFG.userPoolClientId,
      AuthParameters: { USERNAME: username, PASSWORD: password }
    });
  }

  function respondToNewPassword(username, newPassword, sessionToken) {
    return cognitoCall("RespondToAuthChallenge", {
      ChallengeName: "NEW_PASSWORD_REQUIRED",
      ClientId: CFG.userPoolClientId,
      Session: sessionToken,
      ChallengeResponses: { USERNAME: username, NEW_PASSWORD: newPassword }
    });
  }

  /* -------------------------------------------------------------- api calls */

  function api(path, options) {
    options = options || {};
    var headers = options.headers || {};
    headers.Authorization = session.idToken;

    return fetch(CFG.apiBaseUrl.replace(/\/$/, "") + path, {
      method: options.method || "GET",
      headers: headers,
      body: options.body
    }).then(function (res) {
      if (res.status === 401 || res.status === 403) {
        clearSession();
        render();
        throw new Error("Session expired. Please sign in again.");
      }
      return res.text().then(function (text) {
        var data = {};
        try { data = text ? JSON.parse(text) : {}; } catch (e) { /* non-JSON */ }
        if (!res.ok) {
          throw new Error(data.error || ("Request failed (" + res.status + ")"));
        }
        return data;
      });
    });
  }

  /**
   * PUT the file straight to S3. XHR rather than fetch because fetch has no
   * upload progress events.
   */
  function putToS3(url, file, contentType, onProgress) {
    return new Promise(function (resolve, reject) {
      var xhr = new XMLHttpRequest();
      xhr.open("PUT", url, true);
      // Must match the Content-Type baked into the presigned signature,
      // otherwise S3 rejects with 403 SignatureDoesNotMatch.
      xhr.setRequestHeader("Content-Type", contentType);

      xhr.upload.onprogress = function (e) {
        if (e.lengthComputable) { onProgress(e.loaded / e.total); }
      };
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) {
          resolve();
        } else {
          reject(new Error("S3 upload failed (" + xhr.status + ")."));
        }
      };
      xhr.onerror = function () {
        reject(new Error("S3 upload failed. Check the bucket CORS rule."));
      };
      xhr.send(file);
    });
  }

  /* ------------------------------------------------------------------ views */

  function configComplete() {
    return Boolean(CFG.apiBaseUrl && CFG.region && CFG.userPoolClientId) &&
      CFG.apiBaseUrl.indexOf("REPLACE_ME") === -1 &&
      CFG.userPoolClientId.indexOf("REPLACE_ME") === -1;
  }

  function render() {
    if (!configComplete()) {
      show($("config-view"), true);
      show($("auth-view"), false);
      show($("app-view"), false);
      setText($("config-hint"),
        'window.APP_CONFIG = {\n' +
        '  region: "ap-northeast-1",\n' +
        '  apiBaseUrl: "https://xxxxxxxx.execute-api.ap-northeast-1.amazonaws.com",\n' +
        '  userPoolId: "ap-northeast-1_xxxxxxxxx",\n' +
        '  userPoolClientId: "xxxxxxxxxxxxxxxxxxxxxxxxxx",\n' +
        '  maxUploadBytes: 20971520\n' +
        '};');
      return;
    }

    var signedIn = Boolean(session);
    show($("config-view"), false);
    show($("auth-view"), !signedIn);
    show($("app-view"), signedIn);
    show($("signout-btn"), signedIn);
    show($("user-label"), signedIn);

    if (signedIn) {
      var c = session.claims || {};
      setText($("user-label"), c["cognito:username"] || c.email || c.sub || "");
      setText($("max-size-label"), formatBytes(MAX_BYTES));
      loadDocuments();
    }
  }

  /* ------------------------------------------------------------- auth wiring */

  var pendingChallenge = null;

  function authError(message) {
    var el = $("auth-error");
    setText(el, message || "");
    show(el, Boolean(message));
  }

  $("login-form").addEventListener("submit", function (e) {
    e.preventDefault();
    authError("");

    // Reset any challenge left over from a previous attempt. Without this a
    // failed retry shows the new-password form for a user that never got
    // past InitiateAuth.
    pendingChallenge = null;
    show($("new-password-form"), false);
    $("new-password").value = "";

    var username = $("username").value.trim();
    var password = $("password").value;
    var btn = $("login-btn");
    btn.disabled = true;
    btn.textContent = "Signing in…";

    initiateAuth(username, password)
      .then(function (data) {
        if (data.ChallengeName === "NEW_PASSWORD_REQUIRED") {
          pendingChallenge = { username: username, session: data.Session };
          show($("login-form"), false);
          show($("new-password-form"), true);
          return;
        }
        if (data.ChallengeName) {
          throw new Error("Unsupported challenge: " + data.ChallengeName +
            ". Complete it in the Cognito console, then retry.");
        }
        saveSession(data.AuthenticationResult);
        $("password").value = "";
        render();
      })
      .catch(function (err) {
        authError(err.message);
      })
      .finally(function () {
        btn.disabled = false;
        btn.textContent = "Sign in";
      });
  });

  $("new-password-form").addEventListener("submit", function (e) {
    e.preventDefault();
    authError("");

    respondToNewPassword(
      pendingChallenge.username,
      $("new-password").value,
      pendingChallenge.session
    )
      .then(function (data) {
        saveSession(data.AuthenticationResult);
        pendingChallenge = null;
        $("password").value = "";
        $("new-password").value = "";
        show($("new-password-form"), false);
        show($("login-form"), true);
        render();
      })
      .catch(function (err) { authError(err.message); });
  });

  $("signout-btn").addEventListener("click", function () {
    clearSession();
    render();
  });

  /* ----------------------------------------------------------- file picking */

  var selectedFile = null;

  function selectFile(file) {
    if (!file) { return; }

    var isPdf = file.type === "application/pdf" ||
      /\.pdf$/i.test(file.name);

    if (!isPdf) {
      uploadStatus("Only PDF files are accepted.", "err");
      return;
    }
    if (file.size > MAX_BYTES) {
      uploadStatus("File is " + formatBytes(file.size) + ". Limit is " +
        formatBytes(MAX_BYTES) + ".", "err");
      return;
    }

    selectedFile = file;
    setText($("file-name"), file.name);
    setText($("file-meta"), formatBytes(file.size) + " · PDF");
    show($("file-summary"), true);
    $("upload-btn").disabled = false;
    uploadStatus("");
  }

  function clearFile() {
    selectedFile = null;
    $("file-input").value = "";
    show($("file-summary"), false);
    $("upload-btn").disabled = true;
    show($("progress-wrap"), false);
    setProgress(0);
  }

  var dropzone = $("dropzone");

  dropzone.addEventListener("click", function () { $("file-input").click(); });
  dropzone.addEventListener("keydown", function (e) {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      $("file-input").click();
    }
  });

  ["dragenter", "dragover"].forEach(function (evt) {
    dropzone.addEventListener(evt, function (e) {
      e.preventDefault();
      dropzone.classList.add("dragover");
    });
  });

  ["dragleave", "drop"].forEach(function (evt) {
    dropzone.addEventListener(evt, function (e) {
      e.preventDefault();
      dropzone.classList.remove("dragover");
    });
  });

  dropzone.addEventListener("drop", function (e) {
    if (e.dataTransfer.files.length) { selectFile(e.dataTransfer.files[0]); }
  });

  $("file-input").addEventListener("change", function (e) {
    if (e.target.files.length) { selectFile(e.target.files[0]); }
  });

  $("clear-file").addEventListener("click", clearFile);

  /* ---------------------------------------------------------------- upload */

  function setProgress(fraction) {
    var pct = Math.round(fraction * 100);
    $("progress-bar").style.width = pct + "%";
    setText($("progress-label"), pct + "%");
  }

  function uploadStatus(message, kind) {
    var el = $("upload-status");
    el.className = "status" + (kind ? " " + kind : "");
    setText(el, message || "");
    show(el, Boolean(message));
  }

  $("upload-btn").addEventListener("click", function () {
    if (!selectedFile) { return; }

    var btn = $("upload-btn");
    var file = selectedFile;
    var contentType = "application/pdf";

    btn.disabled = true;
    btn.textContent = "Uploading…";
    show($("progress-wrap"), true);
    setProgress(0);
    uploadStatus("Requesting upload URL…");

    api("/documents", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        filename: file.name,
        contentType: contentType,
        sizeBytes: file.size
      })
    })
      .then(function (data) {
        uploadStatus("Uploading to S3…");
        return putToS3(data.uploadUrl, file, contentType, setProgress)
          .then(function () { return data; });
      })
      .then(function (data) {
        setProgress(1);
        uploadStatus("Uploaded. Extracting invoice fields…", "ok");
        clearFile();
        pollUntilSettled();
        return loadDocuments();
      })
      .catch(function (err) {
        uploadStatus(err.message, "err");
      })
      .finally(function () {
        btn.textContent = "Upload";
        btn.disabled = !selectedFile;
      });
  });

  /* ------------------------------------------------------------ document list */

  var BADGES = {
    AWAITING_UPLOAD: ["badge-pending", "Awaiting upload"],
    PENDING_UPLOAD: ["badge-pending", "Pending upload"],
    UPLOADED: ["badge-uploaded", "Uploaded"],
    PROCESSING: ["badge-uploaded", "Extracting…"],
    PROCESSED: ["badge-done", "Processed"],
    FAILED: ["badge-failed", "Failed"]
  };

  // Order matters — this is the display order on each row.
  var FIELD_LABELS = [
    ["vendor", "Vendor"],
    ["invoiceNumber", "Invoice #"],
    ["invoiceDate", "Date"],
    ["dueDate", "Due"],
    ["subtotal", "Subtotal"],
    ["tax", "Tax"],
    ["total", "Total"]
  ];

  function buildExtracted(doc) {
    var extracted = doc.extracted || {};
    var wrap = document.createElement("div");
    wrap.className = "extracted";

    var found = 0;

    FIELD_LABELS.forEach(function (pair) {
      var field = extracted[pair[0]];
      if (!field || !field.value) { return; }
      found++;

      var cell = document.createElement("div");
      cell.className = "field";

      var label = document.createElement("span");
      label.className = "field-label";
      label.textContent = pair[1];

      var value = document.createElement("span");
      value.className = "field-value";
      value.textContent = field.currency
        ? field.value + " " + field.currency
        : field.value;

      // Textract reports per-field confidence; flag anything shaky rather
      // than presenting a guess as fact.
      if (typeof field.confidence === "number" && field.confidence < 80) {
        value.classList.add("field-low");
        value.title = "Low confidence: " + field.confidence.toFixed(1) + "%";
      }

      cell.appendChild(label);
      cell.appendChild(value);
      wrap.appendChild(cell);
    });

    if (doc.lineItemCount) {
      var note = document.createElement("div");
      note.className = "field";
      note.innerHTML = '<span class="field-label">Line items</span>';
      var count = document.createElement("span");
      count.className = "field-value";
      count.textContent = String(doc.lineItemCount);
      note.appendChild(count);
      wrap.appendChild(note);
      found++;
    }

    return found ? wrap : null;
  }

  function renderDocuments(docs) {
    var list = $("doc-list");
    list.innerHTML = "";
    setText($("doc-count"), String(docs.length));

    if (!docs.length) {
      var empty = document.createElement("p");
      empty.className = "muted";
      empty.textContent = "Nothing uploaded yet.";
      list.appendChild(empty);
      return;
    }

    docs.forEach(function (doc) {
      var card = document.createElement("div");
      card.className = "doc-card";

      var row = document.createElement("div");
      row.className = "doc-row doc-row-flush";

      var main = document.createElement("div");
      main.className = "doc-main";

      var title = document.createElement("div");
      title.className = "doc-title";
      title.textContent = doc.filename || doc.documentId;

      var sub = document.createElement("div");
      sub.className = "doc-sub";
      sub.textContent = [
        formatBytes(doc.sizeBytes),
        formatDate(doc.uploadedAt),
        doc.pageCount ? doc.pageCount + (doc.pageCount === 1 ? " page" : " pages") : null
      ].filter(Boolean).join(" · ");

      main.appendChild(title);
      main.appendChild(sub);

      var badgeInfo = BADGES[doc.status] || ["badge-pending", doc.status || "Unknown"];
      var badge = document.createElement("span");
      badge.className = "badge " + badgeInfo[0];
      badge.textContent = badgeInfo[1];

      row.appendChild(main);
      row.appendChild(badge);
      card.appendChild(row);

      if (doc.status === "FAILED" && doc.failureReason) {
        var reason = document.createElement("div");
        reason.className = "doc-reason";
        reason.textContent = doc.failureReason;
        card.appendChild(reason);
      }

      var extracted = buildExtracted(doc);
      if (extracted) { card.appendChild(extracted); }

      list.appendChild(card);
    });
  }

  var PENDING_STATES = ["AWAITING_UPLOAD", "PENDING_UPLOAD", "UPLOADED", "PROCESSING"];
  var pollTimer = null;

  /**
   * Extraction is asynchronous: S3 event -> SQS -> Lambda -> Textract, which
   * takes a few seconds. Poll briefly after an upload so the row moves to
   * Processed on its own instead of the user hunting for the refresh button.
   */
  function pollUntilSettled(attempt) {
    attempt = attempt || 0;
    if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
    if (attempt >= 10) { return; }

    pollTimer = setTimeout(function () {
      api("/documents")
        .then(function (data) {
          var docs = data.documents || [];
          renderDocuments(docs);

          var stillWorking = docs.some(function (doc) {
            return PENDING_STATES.indexOf(doc.status) !== -1;
          });
          if (stillWorking) { pollUntilSettled(attempt + 1); }
        })
        .catch(function () { /* leave the last good render in place */ });
    }, 3000);
  }

  function loadDocuments() {
    return api("/documents")
      .then(function (data) { renderDocuments(data.documents || []); })
      .catch(function (err) {
        var list = $("doc-list");
        list.innerHTML = "";
        var p = document.createElement("p");
        p.className = "error";
        p.textContent = err.message;
        list.appendChild(p);
      });
  }

  $("refresh-btn").addEventListener("click", loadDocuments);

  /* -------------------------------------------------------------- bootstrap */

  session = loadSession();
  render();
})();
