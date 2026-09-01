(async () =>{const urls = [1, 2, 3, 4, 5].map((i) => `https://jsonplaceholder.typicode.com/todos/${i}`);
const all = await Promise.all(urls.map((u) => fetch(u).then((r) => r.json())));
console.log(all.map((t) => t.title));})
