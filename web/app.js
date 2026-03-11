const state = {
  token: localStorage.getItem("omsg_token") || "",
  me: null,
  activeChatId: null,
  ws: null,
};

function byId(id) {
  return document.getElementById(id);
}

function setText(id, value) {
  byId(id).textContent = value;
}

function showJson(id, data) {
  byId(id).textContent = JSON.stringify(data, null, 2);
}

function parseMembers(raw) {
  if (!raw.trim()) {
    return [];
  }
  return raw
    .split(",")
    .map((value) => Number(value.trim()))
    .filter((value) => Number.isInteger(value) && value > 0);
}

function saveToken(token) {
  state.token = token;
  localStorage.setItem("omsg_token", token);
}

function clearToken() {
  state.token = "";
  localStorage.removeItem("omsg_token");
}

async function api(path, options = {}) {
  const { method = "GET", body, auth = true } = options;
  const headers = { "Content-Type": "application/json" };
  if (auth && state.token) {
    headers.Authorization = `Bearer ${state.token}`;
  }

  const response = await fetch(path, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  const contentType = response.headers.get("content-type") || "";
  const payload = contentType.includes("application/json") ? await response.json() : await response.text();

  if (!response.ok) {
    const detail = typeof payload === "string" ? payload : payload.detail || JSON.stringify(payload);
    throw new Error(detail);
  }

  return payload;
}

function renderMessages(messages) {
  const target = byId("message-list");
  target.innerHTML = "";
  for (const message of messages) {
    appendMessage(message);
  }
}

function appendMessage(message) {
  const target = byId("message-list");
  const item = document.createElement("div");
  item.className = "msg";
  item.innerHTML = `<small>#${message.id} user:${message.sender_id}</small><div>${message.content}</div>`;
  target.appendChild(item);
  target.scrollTop = target.scrollHeight;
}

function renderChats(chats) {
  const list = byId("chat-list");
  list.innerHTML = "";

  for (const chat of chats) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.textContent = `${chat.title} (${chat.type})`;
    button.onclick = () => activateChat(chat);
    item.appendChild(button);
    list.appendChild(item);
  }
}

function renderFeed(posts) {
  const list = byId("feed-list");
  list.innerHTML = "";

  for (const post of posts) {
    const item = document.createElement("li");
    item.innerHTML = `<strong>user:${post.author_id}</strong><br/>${post.content}<br/><small>${post.visibility}</small>`;
    list.appendChild(item);
  }
}

function websocketUrl(chatId) {
  const scheme = window.location.protocol === "https:" ? "wss" : "ws";
  const token = encodeURIComponent(state.token);
  return `${scheme}://${window.location.host}/api/realtime/chats/${chatId}/ws?token=${token}`;
}

function disconnectWs() {
  if (state.ws) {
    state.ws.close();
    state.ws = null;
  }
}

function connectWs(chatId) {
  disconnectWs();
  state.ws = new WebSocket(websocketUrl(chatId));

  state.ws.onopen = () => setText("chat-status", "Realtime connected");
  state.ws.onclose = () => setText("chat-status", "Realtime disconnected");
  state.ws.onerror = () => setText("chat-status", "Realtime error");
  state.ws.onmessage = (event) => {
    try {
      const payload = JSON.parse(event.data);
      if (payload.type === "message" && payload.message) {
        appendMessage(payload.message);
      }
      if (payload.type === "error" && payload.message) {
        setText("chat-status", payload.message);
      }
    } catch {
      setText("chat-status", "Invalid realtime payload");
    }
  };
}

async function loadMe() {
  const me = await api("/api/users/me");
  state.me = me;
  showJson("me-block", me);
}

async function loadChats() {
  const chats = await api("/api/chats");
  renderChats(chats);
}

async function activateChat(chat) {
  state.activeChatId = chat.id;
  setText("active-chat-title", `Chat #${chat.id}: ${chat.title}`);
  const messages = await api(`/api/chats/${chat.id}/messages`);
  renderMessages(messages);
  connectWs(chat.id);
}

async function sendMessage() {
  if (!state.activeChatId) {
    setText("chat-status", "Select chat first");
    return;
  }

  const input = byId("message-input");
  const content = input.value.trim();
  if (!content) {
    return;
  }
  input.value = "";

  if (state.ws && state.ws.readyState === WebSocket.OPEN) {
    state.ws.send(JSON.stringify({ type: "message", content }));
    return;
  }

  const message = await api(`/api/chats/${state.activeChatId}/messages`, {
    method: "POST",
    body: { content },
  });
  appendMessage(message);
}

async function register() {
  const username = byId("reg-username").value.trim();
  const email = byId("reg-email").value.trim();
  const password = byId("reg-password").value.trim();

  const data = await api("/api/auth/register", {
    method: "POST",
    body: { username, email, password },
    auth: false,
  });
  saveToken(data.access_token);
  setText("auth-status", "Registered and logged in");
  await initializeWorkspace();
}

async function login() {
  const loginValue = byId("login-login").value.trim();
  const password = byId("login-password").value.trim();

  const data = await api("/api/auth/login", {
    method: "POST",
    body: { login: loginValue, password },
    auth: false,
  });
  saveToken(data.access_token);
  setText("auth-status", "Logged in");
  await initializeWorkspace();
}

async function createChat() {
  const title = byId("chat-title").value.trim();
  const description = byId("chat-description").value.trim();
  const type = byId("chat-type").value;
  const memberIds = parseMembers(byId("chat-members").value);

  await api("/api/chats", {
    method: "POST",
    body: {
      title,
      description,
      type,
      member_ids: memberIds,
    },
  });
  await loadChats();
  setText("chat-status", "Chat created");
}

async function loadFeed() {
  const feed = await api("/api/social/feed");
  renderFeed(feed);
}

async function createPost() {
  const content = byId("post-content").value.trim();
  const visibility = byId("post-visibility").value;
  if (!content) {
    return;
  }

  await api("/api/social/posts", {
    method: "POST",
    body: { content, visibility },
  });
  byId("post-content").value = "";
  await loadFeed();
}

function applyTheme(settings) {
  if (settings.accent_color) {
    document.documentElement.style.setProperty("--accent", settings.accent_color);
  }
}

async function loadTheme() {
  const settings = await api("/api/customization/me");
  byId("theme-name").value = settings.theme;
  byId("accent-color").value = settings.accent_color;
  showJson("theme-block", settings);
  applyTheme(settings);
}

async function saveTheme() {
  const theme = byId("theme-name").value.trim();
  const accentColor = byId("accent-color").value.trim();
  const settings = await api("/api/customization/me", {
    method: "PUT",
    body: {
      theme: theme || undefined,
      accent_color: accentColor || undefined,
    },
  });
  showJson("theme-block", settings);
  applyTheme(settings);
}

async function initializeWorkspace() {
  try {
    await loadMe();
    await loadChats();
    await loadFeed();
    await loadTheme();
  } catch (error) {
    setText("auth-status", error.message);
  }
}

function bindEvents() {
  byId("register-btn").onclick = () => register().catch((error) => setText("auth-status", error.message));
  byId("login-btn").onclick = () => login().catch((error) => setText("auth-status", error.message));
  byId("load-me-btn").onclick = () => loadMe().catch((error) => setText("auth-status", error.message));
  byId("create-chat-btn").onclick = () =>
    createChat().catch((error) => setText("chat-status", error.message));
  byId("send-message-btn").onclick = () =>
    sendMessage().catch((error) => setText("chat-status", error.message));
  byId("create-post-btn").onclick = () =>
    createPost().catch((error) => setText("auth-status", error.message));
  byId("load-feed-btn").onclick = () =>
    loadFeed().catch((error) => setText("auth-status", error.message));
  byId("save-theme-btn").onclick = () =>
    saveTheme().catch((error) => setText("auth-status", error.message));
  byId("load-theme-btn").onclick = () =>
    loadTheme().catch((error) => setText("auth-status", error.message));
}

window.addEventListener("beforeunload", () => disconnectWs());
window.addEventListener("DOMContentLoaded", async () => {
  bindEvents();
  if (!state.token) {
    setText("auth-status", "Login or register to start");
    return;
  }
  try {
    await initializeWorkspace();
    setText("auth-status", "Session restored");
  } catch (error) {
    clearToken();
    setText("auth-status", `Session expired: ${error.message}`);
  }
});
