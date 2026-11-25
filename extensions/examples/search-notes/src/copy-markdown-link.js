import { Clipboard } from "@raycast/api";

export default async function Command(props) {
  await Clipboard.copy(
    "[" +
      props.arguments.title
        .trim()
        .replaceAll("\\", "\\\\")
        .replaceAll("[", "\\[")
        .replaceAll("]", "\\]")
        .replaceAll("\r", " ")
        .replaceAll("\n", " ") +
      "](<" +
      props.arguments.url
        .trim()
        .replaceAll(" ", "%20")
        .replaceAll("\\", "%5C")
        .replaceAll("<", "%3C")
        .replaceAll(">", "%3E")
        .replaceAll("\t", "%09")
        .replaceAll("\r", "%0D")
        .replaceAll("\n", "%0A") +
      ">)"
  );
}
