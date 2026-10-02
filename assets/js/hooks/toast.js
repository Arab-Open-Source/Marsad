export const Toast = {
  mounted() {
    const duration = parseInt(this.el.dataset.duration) || 3000;

    this.timeout = setTimeout(() => {
      this.hide();
    }, duration);
  },

  destroyed() {
    if (this.timeout) {
      clearTimeout(this.timeout);
    }
  },

  hide() {
    this.el.classList.add('animate-slide-down');
    setTimeout(() => {
      this.el.remove();
    }, 200);
  }
};
