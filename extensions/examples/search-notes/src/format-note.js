import { showHUD } from "@raycast/api";

export default async function Command(props) {
  await showHUD("[" + props.arguments.topic + "] " + props.arguments.message);
}
