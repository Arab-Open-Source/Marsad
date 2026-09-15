import { Chart, registerables } from "chart.js"
Chart.register(...registerables)

export const ChartHook = {
  mounted() {
    this._createChart()
    this.handleEvent("chart_update", ({ id, data }) => {
      if (this.el.id === id && this.chart) {
        this.chart.data = data
        this.chart.update()
      }
    })
  },

  updated() {
    const newData = this._parseData()
    if (newData && this.chart) {
      this.chart.data = newData
      this.chart.update()
    }
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
      this.chart = null
    }
  },

  _parseData() {
    try {
      const raw = this.el.dataset.chartData
      if (!raw) return null
      return JSON.parse(raw)
    } catch (_e) {
      return null
    }
  },

  _createChart() {
    const data = this._parseData()
    if (!data) return

    const theme = this.el.dataset.theme || "dark"
    const isDark = theme === "dark"

    this.chart = new Chart(this.el, {
      type: "line",
      data: data,
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        spanGaps: true,
        interaction: { intersect: false, mode: "index" },
        plugins: {
          legend: {
            display: true,
            labels: { color: isDark ? "#cbd5e1" : "#475569", boxWidth: 12, usePointStyle: true }
          },
          tooltip: {
            backgroundColor: isDark ? "#1e293b" : "#ffffff",
            titleColor: isDark ? "#f1f5f9" : "#0f172a",
            bodyColor: isDark ? "#cbd5e1" : "#475569",
            borderColor: isDark ? "#334155" : "#e2e8f0",
            borderWidth: 1,
            callbacks: {
              label: (ctx) => `${ctx.dataset.label}: ${ctx.parsed.y}%`
            }
          }
        },
        scales: {
          x: {
            grid: { color: isDark ? "rgba(148,163,184,0.08)" : "rgba(148,163,184,0.12)", drawBorder: false },
            ticks: { color: isDark ? "#94a3b8" : "#64748b", maxTicksLimit: 8, maxRotation: 0 }
          },
          y: {
            beginAtZero: true,
            min: 0,
            max: 100,
            grid: { color: isDark ? "rgba(148,163,184,0.08)" : "rgba(148,163,184,0.12)", drawBorder: false },
            ticks: { color: isDark ? "#94a3b8" : "#64748b", stepSize: 25, callback: (v) => v + "%" }
          }
        }
      }
    })
  }
}
