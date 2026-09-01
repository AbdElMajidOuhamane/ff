export const json = (data, status = 200) => ({ status, body: JSON.stringify(data) });
export const fail = (message, status) => ({ status, body: JSON.stringify({ error: message }) });
export const notFound = () => fail("Not Found", 404);
export const badRequest = (message) => fail(message || "Bad Request", 400);
export const notAllowed = () => fail("Method Not Allowed", 405);
export const crash = (e) => fail("Internal Server Error: " + (e && e.message ? e.message : e), 500);

export async function readJson(req) {
  const text = await req.text();
  return text ? JSON.parse(text) : {};
}
