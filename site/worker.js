export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Strip /rubybench prefix and normalize path
    let path = url.pathname.replace(/^\/rubybench\/?/, '/') || '/';

    // Ensure we have a valid path
    if (path === '/') {
      path = '/index.html';
    }

    // Proxy to the Pages project
    const pagesUrl = `https://rubybench.pages.dev${path}`;

    const response = await fetch(pagesUrl, {
      method: request.method,
      headers: request.headers,
    });

    // Return the response with appropriate headers
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    });
  }
}
