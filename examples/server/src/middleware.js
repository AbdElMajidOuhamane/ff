
export function withLogger(dispatch) {
  return async (req) => {
    const t0 = Date.now();
    const res = await dispatch(req);
    console.log(`${req.method} ${req.url} -> ${res.status} (${Date.now() - t0}ms)`);
    return res;
  };
}
