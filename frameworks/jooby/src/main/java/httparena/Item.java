package httparena;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

@JsonIgnoreProperties(ignoreUnknown = true)
public class Item {
  public long id;
  public String name;
  public String category;
  public long price;
  public long quantity;
  public boolean active;
  public String[] tags;
  public Rating rating;

  @JsonIgnoreProperties(ignoreUnknown = true)
  public static class Rating {
    public long score;
    public long count;
  }
}
