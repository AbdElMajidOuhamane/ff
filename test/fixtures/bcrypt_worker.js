(async () => {
  try {
    await crypto.bcrypt.hash("test");
    postMessage("unexpected_success");
  } catch (e) {
    postMessage("error:" + e.message);
  }
})();
