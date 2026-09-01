http.serve({ port: 3000 }, (url, method) => {
  const path = url.split("?")[0];

  if (path === "/" && method === "GET")
    return  console.log("Hello") ;

  return { status: 404 };
});
