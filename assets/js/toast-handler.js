export function initToastHandler() {
  window.addEventListener("phx:show-toast", (e) => {
    const container = document.getElementById("toast-container");
    if (!container) return;

    const {id, type, title, message, duration} = e.detail;
    const toast = createToastElement(id, type, title, message);
    
    container.appendChild(toast);

    setTimeout(() => {
      removeToast(toast);
    }, duration || 3000);
  });
}

function createToastElement(id, type, title, message) {
  const toast = document.createElement("div");
  toast.id = id;
  toast.className = "fixed bottom-4 right-4 z-[9999] max-w-md pointer-events-auto animate-slide-up";

  const config = getToastConfig(type);
  
  toast.innerHTML = `
    <div class="flex items-start gap-3 p-4 rounded-lg shadow-xl border backdrop-blur-sm ${config.color}">
      <svg class="w-5 h-5 flex-shrink-0 mt-0.5" fill="currentColor" viewBox="0 0 24 24">
        <use href="/images/heroicons-sprite.svg#${config.icon}"></use>
      </svg>
      <div class="flex-1 min-w-0">
        ${title ? `<p class="text-sm font-semibold mb-1">${escapeHtml(title)}</p>` : ''}
        <p class="text-sm">${escapeHtml(message)}</p>
      </div>
      <button class="flex-shrink-0 hover:opacity-70 transition-opacity" aria-label="Close">
        <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
          <use href="/images/heroicons-sprite.svg#hero-x-mark"></use>
        </svg>
      </button>
    </div>
  `;

  toast.querySelector("button").addEventListener("click", () => removeToast(toast));

  return toast;
}

function getToastConfig(type) {
  const configs = {
    success: {
      color: "bg-green-500/10 border-green-500/20 text-green-400",
      icon: "hero-check-circle"
    },
    error: {
      color: "bg-red-500/10 border-red-500/20 text-red-400",
      icon: "hero-x-circle"
    },
    warning: {
      color: "bg-yellow-500/10 border-yellow-500/20 text-yellow-400",
      icon: "hero-exclamation-triangle"
    },
    info: {
      color: "bg-blue-500/10 border-blue-500/20 text-blue-400",
      icon: "hero-information-circle"
    }
  };

  return configs[type] || configs.info;
}

function removeToast(toast) {
  toast.classList.add("animate-slide-down");
  setTimeout(() => toast.remove(), 200);
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}
