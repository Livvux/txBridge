/* Public, read-only data. No keys, nonces, player identities or admin endpoints. */
(() => {
  for (const widget of document.querySelectorAll('.txbridge-status[data-endpoint]')) {
    const output = widget.querySelector('[role="status"]');
    if (!output) continue;
    const update = async () => {
      if (!document.hidden) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 5000);
        try {
          const response = await fetch(widget.dataset.endpoint, {
            cache: 'no-store', credentials: 'omit', signal: controller.signal,
          });
          if (!response.ok) throw new Error('Status unavailable');
          const status = await response.json();
          output.textContent = status.state === 'online' && Number.isInteger(status.players) && Number.isInteger(status.maxPlayers)
            ? `${status.players} / ${status.maxPlayers} players`
            : 'Status unavailable';
        } catch {
          output.textContent = 'Status unavailable';
        } finally { clearTimeout(timeout); }
      }
      setTimeout(update, 30000);
    };
    update();
  }
})();
