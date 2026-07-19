from fastapi import FastAPI
from mangum import Mangum

app = FastAPI()


@app.get("/hello")
def hello():
    return {"message": "Hello World new test"}


handler = Mangum(app)
