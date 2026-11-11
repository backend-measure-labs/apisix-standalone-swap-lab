FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod .
COPY app/ app/
RUN CGO_ENABLED=0 go build -o /out/app ./app

FROM scratch
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
