# The relay is one file with no dependencies, so this is one COPY and no
# install step. `node:22-alpine` because the whole image is then ~60MB and
# there is nothing in it to keep patched but Node itself.
FROM node:22-alpine

# Not root. The service reads no files and writes none, so there is nothing it
# needs privileges for — and a container that cannot write is one fewer way for
# audio to end up on a disk.
USER node
WORKDIR /app

COPY server.mjs ./

ENV PORT=8787
EXPOSE 8787

# Nothing is buffered to disk, so a container that dies loses nothing but the
# in-flight request — the client falls back to on-device words and still
# produces a brief.
CMD ["node", "server.mjs"]
