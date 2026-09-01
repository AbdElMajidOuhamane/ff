export const json = (data, status = 200) => ({ status, body: JSON.stringify(data) });
export const jsonError = (message, status = 404) => ({ status, body: JSON.stringify({ error: message }) });
