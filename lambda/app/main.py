import os

import boto3
import openpyxl
from fastapi import FastAPI
from mangum import Mangum

app = FastAPI()

s3 = boto3.client("s3")


def read_dummy_data():
    bucket = os.environ["BUCKET_NAME"]
    key = os.environ.get("OBJECT_KEY", "dummy_data.xlsx")

    obj = s3.get_object(Bucket=bucket, Key=key)
    workbook = openpyxl.load_workbook(obj["Body"], read_only=True)
    sheet = workbook.active

    rows = list(sheet.iter_rows(values_only=True))
    header, data_rows = rows[0], rows[1:]
    return [dict(zip(header, row)) for row in data_rows]


@app.get("/hello")
def hello():
    return {"message": "Hello World new test", "dummy_data": read_dummy_data()}


handler = Mangum(app)
