import httpx

response = httpx.get("http://httpbin.org/json", timeout=30)
response.raise_for_status()

print(response.json())
